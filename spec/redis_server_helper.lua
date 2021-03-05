local cqueues = require'cqueues'
cqueues.socket = require'cqueues.socket'
local protocol = require'redis-client.protocol'
local response = require'redis-client.response'

local server = cqueues.socket.listen{ host = '127.0.0.1', port = '0' }
local _, host, port = server:localname()

local M = {
  host = host,
  port = port,
}

local function encode_response(data)
  local data_type
  if type(data) == 'table' then
    data_type = data.type
  end
  if data_type then
    data = data.data
  end

  if data_type == response.STATUS then
    return ('+%s\r\n'):format(data or '')
  elseif data_type == response.ERROR then
    return ('-%s\r\n'):format(data or '')
  elseif data_type == response.INT or (not data_type and type(data) == 'number') then
    return (':%d\r\n'):format(data or 0)
  elseif data_type == response.STRING or (not data_type and type(data) == 'string') then
    if not data then
      return '$-1\r\n'
    else
      return ('$%d\r\n%s\r\n'):format(#data, data)
    end
  elseif data_type == response.ARRAY or (not data_type and type(data) == 'table') then
    if not data then
      return '*-1\r\n'
    else
      local resp = ('*%d\r\n'):format(#data)
      for _,v in ipairs(data) do
        resp = resp .. encode_response(v)
      end
      return resp
    end
  end

  return '-ERR Invalid response'
end

function M.listen(script)
  local conn = server:accept()
  conn:setmode('b', 'b')
  conn:setvbuf('full', math.huge)
  conn:onerror(function() return nil end)

  local command = protocol.read_response(conn)
  while command do
    local resp = table.remove(script or {}, 1)
    if not resp then
      break
    end
    conn:write(encode_response(resp))
    command = protocol.read_response(conn)
  end
  conn:close()
end

return M
