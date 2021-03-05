-- This file is a modified version of that found in https://github.com/daurnimator/lredis.git
--
-- Documentation on the redis protocol found at http://redis.io/topics/protocol
--
local response = require'redis-client.response'

-- Encode and send a redis command.
local function send_command(file, arg)
  arg = arg or {}
  if type(arg) == 'string' then
    arg = {arg}
  end
  if #arg == 0 then
    return nil, 'USAGE', 'No arguments given'
  end

  -- convert the argument array into a RESP array of bulk strings.
  local str_arg = {
    ('*%d\r\n'):format(#arg)
  }
  for _,v in ipairs(arg) do
    v = tostring(v)
    table.insert(str_arg, ('$%d\r\n%s\r\n'):format(#v, v))
  end
  str_arg = table.concat(str_arg)

  -- send the string to the server.
  local ok, err_type, err_msg = file:write(str_arg)
  if not ok then
    return nil, err_type, err_msg
  end
  ok, err_type, err_msg = file:flush()
  if not ok then
    return nil, err_type, err_msg
  end

  return true
end

local function response_renderer(type, data)
  return {
    type = type,
    data = data
  }
end

-- Parse a redis response
local function read_response(file)
  local line, err_type, err_msg = file:read('*L')
  if not line then
    return nil, err_type or 'SOCKET', err_msg or 'EOF'
  end

  -- split the string into its component parts and validate.
  local data_type, data, ending = line:sub(1, 1), line:sub(2, -3), line:sub(-2)
  local int_data = tonumber(data, 10)

  if ending ~= '\r\n' then
    return nil, 'PROTOCOL', 'invalid line ending'
  end

  if data_type == '+' then
    return response_renderer(response.STATUS, data)
  elseif data_type == '-' then
    return response_renderer(response.ERROR, data)
  elseif type(int_data) ~= 'number' then
    return nil, 'PROTOCOL', 'malformed response'
  elseif data_type == ':' and int_data then
    return response_renderer(response.INT, int_data)
  elseif data_type == '$' and int_data == -1 then
    return response_renderer(response.STRING)
  elseif data_type == '$' and int_data >= 0 and int_data <= 512*1024*1024 then
    line, err_type, err_msg = file:read(int_data + 2)
    if not line then
      return nil, err_type, err_msg
    end
    data, ending = line:sub(1, -3), line:sub(-2)
    if ending ~= '\r\n' then
      return nil, 'PROTOCOL', 'malformed response'
    end
    return response_renderer(response.STRING, data)
  elseif data_type == '*' and int_data == -1 then
    return response_renderer(response.ARRAY)
  elseif data_type == '*' and int_data >= 0 then
    local array = {}
    for i = 1, int_data do
      array[i], err_type, err_msg = read_response(file)
      if not array[i] then
        return nil, err_type, err_msg
      end
    end
    return response_renderer(response.ARRAY, array)
  end

  return nil, 'PROTOCOL', 'invalid response'
end

return {
  send_command = send_command,
  read_response = read_response,
}
