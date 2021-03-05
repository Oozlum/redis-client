local redis = {
  protocol = require'redis-client.protocol',
  response = require'redis-client.response',
}

describe('redis-client.protocol sending commands', function()
  it('rejects a missing argument array', function()
    assert(redis.protocol.send_command(true) == nil)
  end)
  it('rejects an empty argument array', function()
    assert(redis.protocol.send_command(true, {}) == nil)
  end)

  it('correctly encodes the argument array', function()
    local command
    redis.protocol.send_command({
      write = function(self, data) command = data; return true end,
      flush = function()return true end,
    }, {
      'PING',
    })
    assert.equal(command, '*1\r\n$4\r\nPING\r\n')
  end)

  it('captures write errors', function()
    redis.protocol.send_command({
      write = function() end,
      flush = function() end,
    }, {
      'PING',
    })
    assert.is_nil(command)
  end)

  it('captures flush errors', function()
    redis.protocol.send_command({
      write = function() return true end,
      flush = function() end,
    }, {
      'PING',
    })
    assert.is_nil(command)
  end)
end)

describe('redis-client.protocol reading responses', function()
  local script = {
    '+OK\n',
    '+OK\r\n',
    '-ERR Error\r\n',
    ':-1\r\n',
    ':NotANumber\r\n',
    '$-1\r\n',

    '$0\r\n',
    '\r\n',

    '$5\r\n',
    'Hello\r\n',

    '$NotANumber\r\n',

    '$1\r\n',
    'Hello\r\n',

    '$10\r\n',
    'Hello\r\n',

    '*-1\r\n',
    '*0\r\n',
    '*NotANumber\r\n',

    '*1\r\n',
    '$5\r\n',
    'Hello\r\n',

    '*1\r\n',
    '$1\r\n',
    'Hello\r\n',

    '£OK\r\n',
  }

  local file = {
    read = function(self, format)
      local line = table.remove(script, 1)
      if type(format) == 'number' then
        line = line:sub(1, format)
        if format ~= #line then
          line = nil
        end
      end
      return line
    end
  }

  it('rejects malformed responses', function() assert.is_nil(redis.protocol.read_response(file)) end)
  it('decodes STATUS responses', function()
    assert.same(redis.protocol.read_response(file), {
      type = redis.response.STATUS,
      data = 'OK',
    })
  end)
  it('decodes ERROR responses', function()
    assert.same(redis.protocol.read_response(file), {
      type = redis.response.ERROR,
      data = 'ERR Error',
    })
  end)
  it('decodes INT responses', function()
    assert.same(redis.protocol.read_response(file), {
      type = redis.response.INT,
      data = -1,
    })
  end)
  it('rejects malformed INT responses', function() assert.is_nil(redis.protocol.read_response(file)) end)
  it('decodes nil STRING responses', function()
    assert.same(redis.protocol.read_response(file), {
      type = redis.response.STRING,
      data = nil,
    })
  end)
  it('decodes empty STRING responses', function()
    assert.same(redis.protocol.read_response(file), {
      type = redis.response.STRING,
      data = '',
    })
  end)
  it('decodes STRING responses', function()
    assert.same(redis.protocol.read_response(file), {
      type = redis.response.STRING,
      data = 'Hello',
    })
  end)
  it('rejects malformed STRING responses', function() assert.is_nil(redis.protocol.read_response(file)) end)
  it('rejects short STRING responses', function() assert.is_nil(redis.protocol.read_response(file)) end)
  it('handles EOF during STRING responses', function() assert.is_nil(redis.protocol.read_response(file)) end)
  it('decodes nil ARRAY responses', function()
    assert.same(redis.protocol.read_response(file), {
      type = redis.response.ARRAY,
      data = nil,
    })
  end)
  it('decodes empty ARRAY responses', function()
    assert.same(redis.protocol.read_response(file), {
      type = redis.response.ARRAY,
      data = {},
    })
  end)
  it('rejects malformed ARRAY responses', function() assert.is_nil(redis.protocol.read_response(file)) end)
  it('decodes ARRAY responses', function()
    assert.same(redis.protocol.read_response(file), {
      type = redis.response.ARRAY,
      data = {
        {
          type = redis.response.STRING,
          data = 'Hello',
        }
      },
    })
  end)
  it('rejects malformed ARRAY content', function() assert.is_nil(redis.protocol.read_response(file)) end)
  it('rejects unknown responses', function() assert.is_nil(redis.protocol.read_response(file)) end)
  it('handles EOF while waiting for response', function() assert.is_nil(redis.protocol.read_response(file)) end)
end)
