-- Redis command handler
local cqueues = require'cqueues'
cqueues.condition = require'cqueues.condition'
local redis = require'redis-client.redis'
local util = require'redis-client.util'
local response = require'redis-client.response'

local M = {
  redis = require'redis-client.redis',
  util = require'redis-client.util',
  response = require'redis-client.response',
}
local command_renderers = {}

-- find the appropriate error handler and call it, returning the result.
local function handle_error(handler, error_handler, err_type, err_msg)
  error_handler = error_handler or (handler or {attrs={}}).attrs.error_handler or M.error_handler
  if error_handler then
    return error_handler(err_type, err_msg)
  end

  return nil, err_type, err_msg
end

-- find the appropriate response renderer and call it, returning the result.
local function render_response(handler, cmd, options, args, type, data)
  local response_renderer = options.response_renderer or (handler or {attrs={}}).attrs.response_renderer or response.new
  return response_renderer(cmd, options, args, type, data)
end

--[[ Base command handler --]]

local function internal_response_renderer(cmd, options, args, type, data)
  return {
    type = type,
    data = data
  }
end

local function internal_error_handler(...)
  return nil, ...
end

-- return a handler object with an index function which transforms handler.foo into
-- handler.call('foo', ...), caching all created functions.
local function new_handler(redis_client, handler_spec)
  local cache = {}

  -- default some handler properties
  handler_spec = handler_spec or {}
  handler_spec.blacklist = handler_spec.blacklist or {}
  handler_spec.precall = handler_spec.precall or {}
  handler_spec.postcall = handler_spec.postcall or {}
  handler_spec.methods = handler_spec.methods or {}

  local handler = {
    attrs = {
      redis_client = redis_client,
    },
    close = function(handler)
      if handler.attrs.redis_client then
        handler.attrs.redis_client:close()
        handler.attrs.redis_client = nil
      end
    end,
    call = function(handler, ...)
      local user_options, args = util.transform_variadic_args_to_tables(...)
      if #args == 0 then
        return handle_error(handler, user_options.error_handler, 'USAGE', 'No command given')
      end
      local cmd = tostring(table.remove(args, 1)):upper()

      if not handler.attrs.redis_client then
        return handle_error(handler, user_options.error_handler, 'USAGE', 'invalid redis client.  Was it closed?')
      end

      -- duplicate the options table so we can add things without upsetting the caller
      -- then inject the handler white and black lists.
      local options = {
        user_options = util.deep_copy(user_options),
        blacklist = util.deep_copy(user_options.blacklist or {}),
        whitelist = (user_options.whitelist and util.deep_copy(user_options.whitelist)) or nil,
        callback = user_options.callback,
      }

      -- apply the white and blacklists.
      if handler_spec.whitelist then
        for _, entry in ipairs(handler_spec.whitelist) do
          table.insert(options.whitelist, entry)
        end
      end
      for _, entry in ipairs(handler_spec.blacklist) do
        table.insert(options.blacklist, entry)
      end

      -- create a state object for use by the hooks.
      local state = {}

      -- call the pre-call hook if present.
      local resp, err_type, err_msg = true, nil, nil
      if handler_spec.precall['^'] then
        resp, err_type, err_msg = handler_spec.precall['^'](handler, state, cmd, options, args)
      end
      if resp and handler_spec.precall[cmd] then
        resp, err_type, err_msg = handler_spec.precall[cmd](handler, state, cmd, options, args)
      end
      if resp and handler_spec.precall['$'] then
        resp, err_type, err_msg = handler_spec.precall['$'](handler, state, cmd, options, args)
      end
      if not resp then
        return handle_error(handler, user_options.error_handler, err_type, err_msg)
      end

      -- make the call using our own error handler and renderer.
      resp, err_type, err_msg = handler.attrs.redis_client:call(cmd, {
        error_handler = internal_error_handler,
        response_renderer = internal_response_renderer,
        blacklist = options.blacklist,
        whitelist = options.whitelist,
      }, args)

      -- call the post-call hook with the results of the actual call
      if handler_spec.postcall['^'] then
        resp, err_type, err_msg = handler_spec.postcall['^'](handler, state, cmd, options, args, resp, err_type, err_msg)
      end
      if handler_spec.postcall[cmd] then
        resp, err_type, err_msg = handler_spec.postcall[cmd](handler, state, cmd, options, args, resp, err_type, err_msg)
      end
      if handler_spec.postcall['$'] then
        resp, err_type, err_msg = handler_spec.postcall['$'](handler, state, cmd, options, args, resp, err_type, err_msg)
      end

      -- if there was an error, report it using the original error handler.
      if not resp then
        return handle_error(handler, user_options.error_handler, err_type, err_msg)
      end

      -- some commands return special objects that cannot be rendered.
      if resp.do_not_render then
        resp = resp.data
      else
        -- do any command-specific rendering, then run the user supplied renderer
        if command_renderers[cmd] then
          resp = command_renderers[cmd](handler, state, cmd, options, args, resp.type, resp.data)
        end
        resp = render_response(handler, cmd, user_options, args, resp.type, resp.data)
      end

      -- finally call the callback and return the response
      if options.callback then
        options.callback(cmd, user_options, args, resp)
      end

      return resp
    end
  }

  return setmetatable(handler, {
    __index = function(t, cmd)
      -- ignore non-string keys, otherwise ipairs will go loopy.
      if type(cmd) ~= 'string' then
        return nil
      end

      if handler_spec.methods[cmd] then
        return handler_spec.methods[cmd]
      end

      if not cache[cmd] then
        cache[cmd] = function(self, ...)
          local options, args = util.transform_variadic_args_to_tables(cmd, ...)
          return self:call(options, args)
        end
      end
      return cache[cmd]
    end
  })
end

--[[ command-specific response renderers --]]
function command_renderers.HGETALL(handler, state, cmd, options, args, type, data)
  if data and type == response.ARRAY then
    repeat
      local name = table.remove(data, 1)
      local value = table.remove(data, 1)
      if name then
        data[name.data] = value
      end
    until name == nil
  end
  return {
    type = type,
    data = data
  }
end

function command_renderers.HMGET(handler, state, cmd, options, args, type, data)
  if data and type == response.ARRAY then
    for i = 2,#args do
      data[args[i]] = data[i - 1]
      data[i - 1] = nil
    end
  end
  return {
    type = type,
    data = data
  }
end

function command_renderers.EXEC(handler, state, cmd, options, args, type, data)
  if data and type == response.ARRAY then
    -- call each of the original renderers.
    for i,_cmd in ipairs(handler.attrs.command_queue or {}) do
      if command_renderers[_cmd.cmd] then
        data[i] = command_renderers[_cmd.cmd](handler, _cmd.state, _cmd.cmd, _cmd.options, _cmd.args, data[i].type, data[i].data)
      end
      data[i] = render_response(handler, _cmd.cmd, _cmd.options.user_options, _cmd.args, data[i].type, data[i].data)
    end
  end

  return {
    type = type,
    data = data
  }
end

--[[ command-specific handler hooks --]]
local function hmset_precall(handler, state, cmd, options, args)
  -- transform { 'hash', { name1 = 'value1', 'name2', 'value2',... } } => { 'hash', 'name1', 'value1', 'name2', 'value2' }
  local kv = args[2]
  if type(kv) == 'table' then
    table.remove(args, 2)
    for i,v in ipairs(kv) do
      table.insert(args, tostring(v))
      kv[i] = nil
    end
    for k,v in pairs(kv) do
      table.insert(args, tostring(k))
      table.insert(args, tostring(v))
    end
  end
  return true
end

--[[ Transaction handler --]]

-- set up a transaction handler.
local function cancel_transaction(xact)
  if xact.attrs.parent.attrs.transaction_lock then
    xact.attrs.parent.attrs.transaction_lock:signal()
    xact.attrs.parent.attrs.transaction_lock = nil
  end
  xact.attrs.in_transaction = nil
end

local transaction_handler_spec = {
  blacklist = {
    'MULTI'
  },
  precall = {
    ['^'] = function(xact, state, cmd, options, args)
      if not xact.attrs.in_transaction then
        return nil, 'USAGE', 'transaction no longer valid'
      end
      -- override the whitelist if we're subscribed.
      if xact.attrs.subscribed then
        options.whitelist = {
          'SUBSCRIBE',
          'PSUBSCRIBE',
          'UNSUBSCRIBE',
          'PUNSUBSCRIBE',
          'RESET',
          'QUIT',
          'EXEC',
          'DISCARD',
        }
      end
      return true
    end,

    HMSET = hmset_precall,

    ['$'] = function(xact, state, cmd, options, args)
      -- push the callback and renderer into the transaction so it can be resolved on EXEC.
      if cmd ~= 'EXEC' and cmd ~= 'DISCARD' and cmd ~= 'RESET' then
        xact.attrs.command_queue = xact.attrs.command_queue or {}
        table.insert(xact.attrs.command_queue, {
          state = state,
          cmd = cmd,
          options = options,
          args = util.deep_copy(args),
        })
      end
      return true
    end,
  },
  postcall = {
    -- enter subscription mode for the subscribe commands
    SUBSCRIBE = function(xact, state, cmd, options, args, resp, err_type, err_msg)
      xact.attrs.subscribed = true
      return resp, err_type, err_msg
    end,
    PSUBSCRIBE = function(xact, state, cmd, options, args, resp, err_type, err_msg)
      xact.attrs.subscribed = true
      return resp, err_type, err_msg
    end,

    -- cancel the transaction after DISCARD, EXEC and RESET
    DISCARD = function(xact, state, cmd, options, args, resp, err_type, err_msg)
      cancel_transaction(xact)
      return resp, err_type, err_msg
    end,
    EXEC = function(xact, state, cmd, options, args, resp, err_type, err_msg)
      cancel_transaction(xact)

      if resp and resp.type ~= response.ERROR then
        -- propagate the subscription state to the parent.
        xact.attrs.parent.attrs.subscribed = xact.attrs.subscribed

        if resp.type == response.ARRAY then
          -- call each of the original callbacks.
          for i,_cmd in ipairs(xact.attrs.command_queue or {}) do
            if _cmd.options.callback then
              _cmd.options.callback(_cmd.cmd, _cmd.options.user_options, _cmd.args, resp.data[i])
            end
          end
        end
      end

      return resp, err_type, err_msg
    end,
    RESET = function(xact, state, cmd, options, args, resp, err_type, err_msg)
      cancel_transaction(xact)
      return resp, err_type, err_msg
    end,
    -- cancel the transaction on any error.
    ['$'] = function(xact, state, cmd, options, args, resp, err_type, err_msg)
      if not resp or resp.type == response.ERROR then
        cancel_transaction(xact)
      end
      return resp, err_type, err_msg
    end,
  },
}

--[[ Base command handler --]]

-- set up the basic operations of a command handler.
local command_handler_spec = {
  blacklist = {
    'EXEC',
    'DISCARD'
  },
  precall = {
    ['^'] = function(handler, state, cmd, options, args)
      if handler.attrs.transaction_lock and not cqueues.running() then
        return nil, 'USAGE', 'Transaction in progress and cannot wait -- not in a coroutine'
      end
      while handler.attrs.transaction_lock do
        handler.attrs.transaction_lock:wait()
      end
      -- override the whitelist if we're subscribed.
      if handler.attrs.subscribed then
        options.whitelist = {
          'SUBSCRIBE',
          'PSUBSCRIBE',
          'UNSUBSCRIBE',
          'PUNSUBSCRIBE',
          'RESET',
          'QUIT',
        }
      end
      return true
    end,

    HMSET = hmset_precall,

    -- create a transaction lock now to prevent other coroutines from pipelining
    -- commands while MULTI is pending.
    MULTI = function(handler, state, cmd, options, args)
      if handler.attrs.transaction_lock then
        return nil, 'USAGE', 'Unexpected transaction state'
      end
      handler.attrs.transaction_lock = cqueues.condition.new()
      return true
    end,
  },
  postcall = {
    -- if the MULTI command finished successfully create and return a transaction
    -- handler.  Otherwise, remove the transaction lock and return an error.
    MULTI = function(handler, state, cmd, options, args, resp, err_type, err_msg)
      if not resp or resp.type == response.ERROR then
        cancel_transaction{
          attrs = {
            parent = handler
          }
        }
      end

      if not resp then
        return nil, err_type, err_msg
      elseif resp.type == response.ERROR then
        return nil, 'USAGE', resp.data
      end

      local transaction = new_handler(handler.attrs.redis_client, transaction_handler_spec)
      transaction.attrs.parent = handler
      transaction.attrs.in_transaction = true
      return {
        do_not_render = true,
        data = transaction
      }
    end,

    SUBSCRIBE = function(handler, state, cmd, options, args, resp, err_type, err_msg)
      if resp and resp.type ~= response.ERROR then
        handler.attrs.subscribed = true
      end
      return resp, err_type, err_msg
    end,
    PSUBSCRIBE = function(handler, state, cmd, options, args, resp, err_type, err_msg)
      if resp and resp.type ~= response.ERROR then
        handler.attrs.subscribed = true
      end
      return resp, err_type, err_msg
    end,

    RESET = function(handler, state, cmd, options, args, resp, err_type, err_msg)
      if resp and resp.type ~= response.ERROR then
        handler.attrs.subscribed = nil
      end
      return resp, err_type, err_msg
    end
  },

  methods = {
    next_publication = function(handler, options)
      options = options or {}
      if not handler.attrs.subscribed then
        return handle_error(handler, options.error_handler, 'USAGE', 'Not subscribed')
      end
      local resp, err_type, err_msg = handler.attrs.redis_client:next_publication({
        error_handler = internal_error_handler,
        response_renderer = internal_response_renderer,
        timeout = options.timeout,
      })
      if not resp then
        return handle_error(handler, options.error_handler, err_type, err_msg)
      end
      return render_response(handler, 'MESSAGE', options, {}, resp.type, resp.data)
    end
  },
}

M.new = function(redis_client)
  return new_handler(redis_client, command_handler_spec)
end
M.connect = function(host, port, error_handler)
  local redis_client, err_type, err_msg = redis.connect(host, port, error_handler)
  if not redis_client then
    return nil, err_type, err_msg
  end
  return new_handler(redis_client, command_handler_spec)
end
M.error_handler = function(err_type, err_msg)
  return nil, err_type, err_msg
end

return M
