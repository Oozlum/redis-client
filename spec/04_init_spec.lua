local redis = require'redis-client'
redis.redis = require'redis-client.redis'
redis.protocol = require'redis-client.protocol'
redis.response = require'redis-client.response'
redis.util = require'redis-client.util'
local server = require'spec/redis_server_helper'
local cqueues = require'cqueues'
cqueues.socket = require'cqueues.socket'
cqueues.condition = require'cqueues.condition'

local cq = cqueues.new()

local busted_it = it
local it = function(desc, func, test_script, timeout)
  timeout = timeout or 1

  busted_it(desc, function()
    cq:wrap(function() server.listen(redis.util.deep_copy(test_script or {})) end)
    cq:wrap(func)

    assert(cq:loop(timeout))
    assert(cq:empty())
  end)
end

describe('redis-client module basic operation', function()
  local script = {
    { type = redis.response.STATUS, data = 'PONG' },
    { type = redis.response.STATUS, data = 'PONG' },
    { type = redis.response.STATUS, data = 'PONG' },
  }

  it('establishes a TCP connection to a redis server', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    local response = rc:ping()
    assert.same(response, script[1])
    rc:close()
  end, script)

  it('can use an existing redis.redis client', function()
    local rc = redis.redis.connect(server.host, server.port)
    rc = redis.new(rc)
    finally(function() rc:close() end)

    local response = rc:ping()
    assert.same(response, script[1])
    rc:close()
  end, script)

  it('catches errors with its default handler', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    assert.has.errors(function() rc:ping() end)
    rc:close()
  end, {})

  it('selects the correct error handler', function()
    local old_handler = redis.error_handler
    local rc = redis.connect(server.host, server.port)
    finally(function()
      redis.error_handler = old_handler
      rc:close()
    end)

    redis.error_handler = spy.new(function(...) return nil, ... end)
    rc:ping()
    assert.spy(redis.error_handler).was.called(1)

    rc.attrs.error_handler = spy.new(function(...) return nil, ... end)
    rc:ping()
    assert.spy(rc.attrs.error_handler).was.called(1)

    local error_handler = spy.new(function(...) return nil, ... end)
    rc:ping({
      error_handler = error_handler
    })
    assert.spy(error_handler).was.called(1)

    redis.error_handler = old_handler
    rc:close()
  end, {})

  it('returns nil,err,msg with no error handler set', function()
    local old_handler = redis.error_handler
    local rc = redis.connect(server.host, server.port)
    finally(function()
      redis.error_handler = old_handler
      rc:close()
    end)

    redis.error_handler = nil
    local resp = rc:ping()
    assert.is_nil(resp)

    rc:close()
  end, {})

  it('rejects empty command lists and non-string methods', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    assert.has.errors(function() rc:call() end)
    assert.is_nil(rc[1])

    rc:close()
  end)

  it('selects the correct response renderer', function()
    local old_renderer = redis.response.new
    local rc = redis.connect(server.host, server.port)
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
    rc:ping()
    assert.spy(redis.response.new).was.called(1)

    rc.attrs.response_renderer = new_renderer()
    rc:call('ping')
    assert.spy(rc.attrs.response_renderer).was.called(1)

    local response_renderer = new_renderer()
    rc:call('ping', {
      response_renderer = response_renderer
    })
    assert.spy(response_renderer).was.called(1)

    rc:close()
  end, script)

  it('supports callbacks', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    local callback = spy.new(function() end)
    rc:ping({
      callback = callback
    })
    assert.spy(callback).was.called(1)

    rc:close()
  end, {
    { type = redis.response.STATUS, data = 'PONG' },
  })

  it('rejects a closed client', function()
    local rc = redis.connect(server.host, server.port)

    rc:close()
    local response = rc:ping({
      error_handler = function(...) return nil, ... end,
    })
    assert.is_nil(response)
  end, script)
end)

describe('redis-client module client blacklist checking', function()
  it('rejects DISCARD outside a transaction', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)
    assert.has.errors(function() rc:discard() end)
    rc:close()
  end)

  it('rejects EXEC outside a transaction', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)
    assert.has.errors(function() rc:discard() end)
    rc:close()
  end)

  it('handles a user blacklist', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)
    assert.has.errors(function() rc:get({
      blacklist = {'GET'}
    }) end)
    rc:close()
  end)

  it('a user blacklist doesn\'t overwrite the in-built one', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)
    assert.has.errors(function() rc:discard({
      blacklist = {'GET'}
    }) end)
    rc:close()
  end)

  it('handles a user whitelist', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)
    assert.has.errors(function() rc:get({
      whitelist = {'HMSET'}
    }) end)
    rc:close()
  end)
end)

describe('redis-client module transaction handling', function()
  it('manages transactions with multiple co-routines', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    local cond = cqueues.condition.new()
    cq:wrap(function()
      cond:wait()
      cond:signal()
      local resp = rc:get('string')
      assert.same({ type = redis.response.STRING, data = 'after transaction'}, resp)
      rc:close()
    end)

    cq:wrap(function()
      local multi = rc:multi()
      cond:signal()
      cond:wait()
      local resp = multi:get('string')
      assert.same({ type = redis.response.STATUS, data = 'QUEUED' }, resp)
      local resp = multi:exec()
      assert.same({ type = redis.response.ARRAY, data = { { type = redis.response.STRING, data = 'inside transaction'} } }, resp)
    end)
  end, {
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'QUEUED' },
    { type = redis.response.ARRAY, data = {
        { type = redis.response.STRING, data = 'inside transaction' },
      }
    },
    { type = redis.response.STRING, data = 'after transaction' },
  })

  busted_it('rejects operations outside of an open transaction when not using co-routines', function()
    local function dummy() return true end
    local rc = redis.new(redis.redis.new({
      onerror = dummy,
      setmode = dummy,
      setvbuf = dummy,
      write = dummy,
      flush = dummy,
      read = function()
        return '+QUEUED\r\n'
      end,
    }))

    local multi = rc:multi()
    local resp = multi:get('string')
    assert.same({ type = redis.response.STATUS, data = 'QUEUED' }, resp)
    assert.has.errors(function() rc:get('string') end)
  end)

  busted_it('rejects nested transactions', function()
    local function dummy() return true end
    local rc = redis.new(redis.redis.new({
      onerror = dummy,
      setmode = dummy,
      setvbuf = dummy,
      write = dummy,
      flush = dummy,
      read = function()
        return '+OK\r\n'
      end,
    }))

    local multi = rc:multi()
    assert.has.errors(function() multi:multi() end)
  end)

  it('re-calls transaction callbacks and renderers when the exec has completed', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    local multi = rc:multi()
    local callback = spy.new(function() end)
    local renderer = spy.new(function() end)
    multi:ping({
      response_renderer = function(cmd, options, args, type, data)
        renderer()
        return { type = type, data = data }
      end,
      callback = callback
    })
    assert.spy(callback).was.called(1)
    assert.spy(renderer).was.called(1)
    multi:exec()
    assert.spy(callback).was.called(2)
    assert.spy(renderer).was.called(2)

    rc:close()
  end, {
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'QUEUED' },
    { type = redis.response.ARRAY, data = {
        { type = redis.response.STATUS, data = 'PONG' },
      }
    },
  })

  it('gives an error if the transaction has already finished', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    local multi = rc:multi()
    multi:ping()
    multi:exec()
    assert.has.errors(function() multi:ping() end)
    rc:close()
  end, {
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'QUEUED' },
    { type = redis.response.ARRAY, data = {
        { type = redis.response.STATUS, data = 'PONG' },
      }
    },
  })

  it('handles errors on MULTI', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    assert.has.errors(function() rc:multi() end)

    rc:close()
  end, {
    { type = redis.response.ERROR, data = 'ERR error' },
  })

  it('cancels a transaction on RESET and DISCARD', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    local multi = rc:multi()
    multi:discard()
    rc:ping()
    multi = rc:multi()
    multi:reset()
    rc:ping()
    rc:close()
  end, {
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'PONG' },
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'PONG' },
  })
end)

describe('redis-client module data transformation', function()
  it('transforms HGETALL responses into key-value pairs', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    local resp = rc:hgetall('hash')
    assert.same({
      type = redis.response.ARRAY,
      data = {
        key = { type = redis.response.STRING, data = 'value' },
      }
    }, resp)
    rc:close()
  end, {
    { type = redis.response.ARRAY,
      data = {
        { type = redis.response.STRING, data = 'key' },
        { type = redis.response.STRING, data = 'value' },
      }
    }
  })

  it('transformation also works in transactions', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    local multi = rc:multi()
    multi:hgetall('hash')
    local resp = multi:exec()
    assert.same({
      type = redis.response.ARRAY,
      data = {
        {
          type = redis.response.ARRAY,
          data = {
            key = { type = redis.response.STRING, data = 'value' },
          }
        },
      }
    }, resp)
    rc:close()
  end, {
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'QUEUED' },
    { type = redis.response.ARRAY, data = {
        { type = redis.response.ARRAY, data = {
            { type = redis.response.STRING, data = 'key' },
            { type = redis.response.STRING, data = 'value' },
          }
        }
      }
    }
  })

  it('transforms HMGET responses into key-value pairs', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    local resp = rc:hmget('hash', 'key')
    assert.same({
      type = redis.response.ARRAY,
      data = {
        key = { type = redis.response.STRING, data = 'value' },
      }
    }, resp)
    rc:close()
  end, {
    { type = redis.response.ARRAY,
      data = {
        { type = redis.response.STRING, data = 'value' },
      }
    }
  })

  busted_it('transforms HMSET key-value arguments into arrays', function()
    local output = {}
    local function dummy() return true end
    local rc = redis.new(redis.redis.new({
      onerror = dummy,
      setmode = dummy,
      setvbuf = dummy,
      write = function(self, data)
        for s in data:gmatch('[^\r\n]+\r\n') do
          table.insert(output, s)
        end
        return true
      end,
      flush = dummy,
      read = function()
        return table.remove(output, 1)
      end,
    }))

    local resp = rc:hmset('hash', { 'a', 'b', key = 'value' })
    assert.same({
      type = redis.response.ARRAY,
      data = {
        { type = redis.response.STRING, data = 'HMSET', },
        { type = redis.response.STRING, data = 'hash', },
        { type = redis.response.STRING, data = 'a', },
        { type = redis.response.STRING, data = 'b', },
        { type = redis.response.STRING, data = 'key', },
        { type = redis.response.STRING, data = 'value', },
      }
    }, resp)
  end)
end)

describe('redis-client module pub/sub', function()
  it('prevents non pub/sub commands when subscribed', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    rc:subscribe('test')
    assert.has.errors(function() rc:ping() end)
    rc:reset()
    local multi = rc:multi()
    multi:subscribe('test')
    assert.has.errors(function() multi:ping() end)
    rc:close()
  end, {
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'OK' },
  })

  it('preserves subscription status through transactions', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    local multi = rc:multi()
    multi:psubscribe('test')
    multi:discard()
    local resp = rc:ping({ error_handler = function(...) return nil, ... end })
    assert.not_nil(resp)

    multi = rc:multi()
    multi:subscribe('test')
    multi:exec()
    assert.has.errors(function() rc:ping() end)
    assert.has.errors(function() rc:multi() end)

    rc:close()
  end, {
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'OK' },
  })

  it('will not wait for publications when not subscribed', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    assert.has.errors(function() rc:next_publication() end)

    rc:close()
  end)

  it('timeout while waiting for publications', function()
    local rc = redis.connect(server.host, server.port)
    finally(function() rc:close() end)

    rc:subscribe('test')
    rc:psubscribe('test*')
    redis.protocol.send_command(rc.attrs.redis_client.socket, 'PUBLISH')
    local resp = rc:next_publication({ timeout = 0.5 })
    assert.same({
      type = redis.response.ARRAY,
      data = {
        { type = redis.response.STRING, data = 'pmessage' },
        { type = redis.response.STRING, data = 'test*' },
        { type = redis.response.STRING, data = 'test' },
        { type = redis.response.STRING, data = 'a message' },
      }
    }, resp)
    local resp = rc:next_publication({ timeout = 0.5 })
    assert.same({ type = redis.response.ARRAY }, resp)

    rc:close()
  end, {
    { type = redis.response.STATUS, data = 'OK' },
    { type = redis.response.STATUS, data = 'OK' },
    {
      type = redis.response.ARRAY,
      data = {
        { type = redis.response.STRING, data = 'pmessage' },
        { type = redis.response.STRING, data = 'test*' },
        { type = redis.response.STRING, data = 'test' },
        { type = redis.response.STRING, data = 'a message' },
      }
    }
  })

  busted_it('handles publication errors', function()
    local output = {
      '+OK\r\n',
      '(\r\n'
    }
    local function read()
      return table.remove(output, 1)
    end
    local function dummy() return true end
    local rc = redis.new(redis.redis.new({
      onerror = dummy,
      setmode = dummy,
      setvbuf = dummy,
      write = function(self, data)
        return true
      end,
      flush = dummy,
      read = read,
      xread = read
    }))

    rc:subscribe('test')
    assert.has.errors(function() rc:next_publication() end)
  end)

end)
