describe('redis-client.redis module', function()
  local redis = require'redis-client'
  redis.redis = require'redis-client.redis'
  redis.protocol = require'redis-client.protocol'
  redis.response = require'redis-client.response'
  redis.util = require'redis-client.util'
  local server = require'spec/redis_server_helper'
  local cqueues = require'cqueues'
  cqueues.socket = require'cqueues.socket'
  cqueues.condition = require'cqueues.condition'

  local script = {
    { type = redis.response.STATUS, data = 'PONG' },
    { type = redis.response.STATUS, data = 'PONG' },
    { type = redis.response.STATUS, data = 'PONG' },
  }

  local cq = cqueues.new()

  local test_it = it
  local it = function(desc, func, test_script, timeout)
    timeout = timeout or 1

    test_it(desc, function()
      cq:wrap(function() server.listen(redis.util.deep_copy(test_script or {})) end)
      cq:wrap(func)

      assert(cq:loop(timeout))
      assert(cq:empty())
    end)
  end

  it('establishes a TCP connection to a redis server', function()
    local rc = redis.redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    local response = rc:call('ping')
    assert.same(response, script[1])
    rc:close()
  end, script)

  it('can use an existing socket', function()
    local rc = redis.redis.new(cqueues.socket.connect{host = server.host, port = server.port}:connect())
    finally(function() rc:close() end)

    local response = rc:call('ping')
    assert.same(response, script[1])
    rc:close()
  end, script)

  it('rejects a closed socket', function()
    local rc = redis.redis.new(cqueues.socket.connect{host = server.host, port = server.port}:connect())

    rc:close()
    local response = rc:call('ping', {
      error_handler = function(...) return nil, ... end,
    })
    assert.is_nil(response)
  end, script)

  it('rejects an invalid socket', function()
    local rc = redis.redis.new(cqueues.socket.connect{host = server.host, port = server.port}:connect())

    rc:close()
    rc.socket = nil
    local response = rc:call('ping', {
      error_handler = function(...) return nil, ... end,
    })
    assert.is_nil(response)
  end, script)

  it('catches errors with its default handler', function()
    local rc = redis.redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    local old_error_handler = redis.redis.error_handler
    redis.redis.error_handler = spy.new(old_error_handler)
    rc:call('ping')
    assert.spy(redis.redis.error_handler).was.called(1)
    redis.redis.error_handler = old_error_handler

    rc:close()
  end, {})

  it('selects the correct error handler', function()
    local old_handler = redis.redis.error_handler
    local rc = redis.redis.connect(server.host, server.port)
    finally(function()
      redis.redis.error_handler = old_handler
      rc:close()
    end)

    redis.redis.error_handler = spy.new(function() end)
    rc:call('ping')
    assert.spy(redis.redis.error_handler).was.called(1)

    rc.error_handler = spy.new(function() end)
    rc:call('ping')
    assert.spy(rc.error_handler).was.called(1)

    local error_handler = spy.new(function() end)
    rc:call('ping', {
      error_handler = error_handler
    })
    assert.spy(error_handler).was.called(1)

    rc:close()
  end, {})

  it('returns nil,err,msg with no error handler set', function()
    local old_handler = redis.redis.error_handler
    local rc = redis.redis.connect(server.host, server.port)
    finally(function()
      redis.redis.error_handler = old_handler
      rc:close()
    end)

    redis.redis.error_handler = nil
    local resp = rc:call('ping')
    assert.is_nil(resp)

    rc:close()
  end, {})

  it('selects the correct response renderer', function()
    local old_renderer = redis.response.new
    local rc = redis.redis.connect(server.host, server.port)
    finally(function()
      redis.response.new = old_renderer
      rc:close()
    end)

    local function new_renderer()
      return spy.new(function(...)
        return old_renderer(...)
      end)
    end

    redis.response.new = new_renderer()
    rc:call('ping')
    assert.spy(redis.response.new).was.called(1)

    rc.response_renderer = new_renderer()
    rc:call('ping')
    assert.spy(rc.response_renderer).was.called(1)

    local response_renderer = new_renderer()
    rc:call('ping', {
      response_renderer = response_renderer
    })
    assert.spy(response_renderer).was.called(1)

    rc:close()
  end, script)

  local publications = {
    {
      type = redis.response.ARRAY,
      data = {
        { type = redis.response.STRING, data = 'pmessage', },
        { type = redis.response.STRING, data = 'channel*', },
        { type = redis.response.STRING, data = 'channel', },
        { type = redis.response.STRING, data = 'A message', },
      },
    }
  }

  it('reads a publication', function()
    local rc = redis.redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    -- poke the mock server so that it responds with a message.
    redis.protocol.send_command(rc.socket, 'PUBLISH')

    local resp = rc:next_publication()
    assert.same(publications[1], resp)

    rc:close()
  end, publications)

  it('times out waiting for a publication', function()
    local rc = redis.redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    local resp = rc:next_publication({ timeout = 1 })
    assert.same({ type = redis.response.ARRAY }, resp)

    rc:close()
  end, {}, 2)

  it('handles errors while waiting for a publication', function()
    local rc = redis.redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    -- poke the mock server so that it responds with a message.
    redis.protocol.send_command(rc.socket, 'PUBLISH')

    local resp = rc:next_publication({
      error_handler = function(...) return nil, ... end,
    })
    assert.is_nil(resp)

    rc:close()
  end, {})

  it('handles multiple co-routines using the same client', function()
    local rc = redis.redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    local cond = cqueues.condition.new()
    cq:wrap(function()
      cond:signal()
      local resp = rc:call('get', 'string1')
      assert.same({ type = redis.response.STRING, data = 'string1' }, resp)
    end)

    cq:wrap(function()
      cond:wait()
      local resp = rc:call('get', 'string2')
      assert.same({ type = redis.response.STRING, data = 'string2' }, resp)
      rc:close()
    end)
  end, {
    { type = redis.response.STRING, data = 'string1' },
    { type = redis.response.STRING, data = 'string2' },
  }, 2)

  it('uses white- and blacklists correctly', function()
    local rc = redis.redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    local resp = rc:call('ping', {
      error_handler = function(...) return nil, ... end,
      blacklist = {'PING'},
    })
    assert.is_nil(resp)

    resp = rc:call('ping', {
      error_handler = function(...) return nil, ... end,
      whitelist = {'PING'},
      blacklist = {'PING'},
    })
    assert.same({ type = redis.response.STATUS, data = 'PONG' }, resp)

    resp = rc:call('ping', {
      error_handler = function(...) return nil, ... end,
      whitelist = {},
    })
    assert.is_nil(resp)
    rc:close()
  end, script)

  it('rejects calls with no arguments', function()
    local rc = redis.redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    local resp = rc:call({
      error_handler = function(...) return nil, ... end,
    })
    assert.is_nil(resp)
    rc:close()
  end)
end)
