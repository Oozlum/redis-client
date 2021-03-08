local protocol = require 'redis-client.protocol'
local response = require 'redis-client.response'
local util = require 'redis-client.util'
local cqueues = require'cqueues'
cqueues.socket = require'cqueues.socket'
cqueues.condition = require'cqueues.condition'
cqueues.errno = require'cqueues.errno'

local M = {}

-- format and return a socket error for the given code.
local function socket_error(code)
  if not code then
    code = 'Unknown error'
  end
  if type(code) == 'string' then
    return 'SOCKET', code
  end
  return 'SOCKET', ('%s %s'):format(cqueues.errno[code] or '', cqueues.errno.strerror(code))
end

-- format and return a protocol error.
local function protocol_error(err_type, err_msg)
  if err_type == 'SOCKET' then
    err_type, err_msg = socket_error(err_msg)
  end
  return err_type, err_msg
end

-- find the appropriate error handler and call it, returning the result.
local function handle_error(client, error_handler, err_type, err_msg)
  error_handler = error_handler or (client or {}).error_handler or M.error_handler
  if error_handler then
    return error_handler(err_type, err_msg)
  end

  return nil, err_type, err_msg
end

local function close_client(client)
  if client.socket ~= false then
    client.socket:close()
    client.socket = false
  end
end

-- if a whitelist is given, only accept commands in the whitelist.
-- if a blacklist is given, reject commands that are in it.
local function validate_command(options, command)
  if options.whitelist then
    for _,v in ipairs(options.whitelist) do
      if tostring(v):upper() == command then return true end
    end
    return false
  end

  for _,v in ipairs(options.blacklist or {}) do
    if tostring(v):upper() == command then return false end
  end

  return true
end

-- call the redis function and return the response.
-- return nil, err_type, err_msg on error.
local function redis_pcall(client, ...)
  local options, args = util.transform_variadic_args_to_tables(...)

  if #args == 0 then
    return nil, 'USAGE', 'no arguments given'
  end

  args[1] = tostring(args[1]):upper()
  if not validate_command(options, args[1]) then
    return nil, 'USAGE', ('command "%s" not permitted at this time'):format(args[1])
  end

  if client.socket == false then
    return nil, 'USAGE', 'socket already closed'
  elseif not client.socket then
    return nil, 'USAGE', 'invalid socket'
  end

  local cond = cqueues.condition.new()
  local resp, err_type, err_msg = protocol.send_command(client.socket, args)
  if not resp then
    return nil, protocol_error(err_type, err_msg)
  end
  table.insert(client.fifo, cond)
  if client.fifo[1] ~= cond then
    cond:wait()
  end
  -- read the response, signal the next command in the queue and then deal with errors.
  resp, err_type, err_msg = protocol.read_response(client.socket)
  table.remove(client.fifo, 1)
  if client.fifo[1] then
    client.fifo[1]:signal()
  end

  if resp then
    local renderer = options.response_renderer or client.response_renderer or M.response_renderer or response.new
    local cmd = table.remove(args, 1)

    return renderer(cmd, options, args, resp.type, resp.data)
  end

  return nil, protocol_error(err_type, err_msg)
end

-- call the redis function and return the response.
-- call the registered error handler on error and return the results.
local function redis_call(client, ...)
  local options, args = util.transform_variadic_args_to_tables(...)

  local resp, err_type, err_msg = client:pcall(options, args)
  if not resp then
    return handle_error(client, options.error_handler, err_type, err_msg)
  end

  return resp
end

-- read the next publication to our subscribed channels.
local function redis_next_publication(client, options)
  options = options or {}
  local resp, err_type, err_msg = protocol.read_response({
    read = function(self, format)
      return client.socket:xread(format, nil, options.timeout)
    end})
  if not resp then
    err_type, err_msg = protocol_error(err_type, err_msg)
    if err_type == 'SOCKET' and err_msg:sub(1, 9) == 'ETIMEDOUT' then
      resp = {
        type = response.ARRAY
      }
    else
      return handle_error(client, options.error_handler, err_type, err_msg)
    end
  end

  local renderer = options.response_renderer or client.response_renderer or M.response_renderer or response.new
  return renderer('MESSAGE', options, {}, resp.type, resp.data)
end

--[[ Static module functions --]]

-- override the default socket handler so that it returns all errors rather than
-- throwing them.
local function socket_error_handler(socket, method, code, level)
  socket:clearerr('rw')
  return code
end

local function new(socket, error_handler)
  socket:onerror(socket_error_handler)
  socket:setmode('b', 'b')
  socket:setvbuf('full', math.huge) -- 'infinite' buffering; no write locks needed
  return {
    socket = socket,
    error_handler = error_handler,
    fifo = {},
    close = close_client,
    pcall = redis_pcall,
    call = redis_call,
    next_publication = redis_next_publication,
  }
end

local function connect_tcp(host, port, error_handler)
  cqueues.socket.onerror(socket_error_handler)
  local socket, err_code = cqueues.socket.connect({
    host = host or '127.0.0.1',
    port = port or '6379',
    nodelay = true,
  })

  if not socket then return handle_error(nil, error_handler, socket_error(err_code)) end

  socket:onerror(socket_error_handler)
  local ok
  ok, err_code = socket:connect()
  if not ok then return handle_error(nil, error_handler, socket_error(err_code)) end

  return new(socket, error_handler)
end

M.new = new
M.connect = connect_tcp
M.error_handler = function(err_type, err_msg)
  error(('%s %s'):format(tostring(err_type), tostring(err_msg)), 2)
end

return M
