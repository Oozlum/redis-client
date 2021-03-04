-- general utility functions.

-- transform a variadic argument list into a two-table argument list as follows:
-- () => ({},{})
-- ({a}) => ({a},{})
-- ({a},x,y,z,...) => ({a},{x,y,z,...})
-- ({a},{b},...) => ({a},{b})
-- (x,y,z,...) => ({},{x,y,z,...})
-- (x,{a},...) => ({a},{x,...})
-- (x,{a},{y,z},...) => ({a},{x,y,z})
local function transform_variadic_args_to_tables(...)
  local first_arg, options
  local args = {...}
  if type(args[1]) ~= 'table' then
    first_arg = table.remove(args, 1)
  end
  if type(args[1]) == 'table' then
    options = table.remove(args, 1)
  end
  if type(args[1]) == 'table' then
    args = args[1]
  end
  options = options or {}
  args = args or {}
  if first_arg then
    table.insert(args, 1, first_arg)
  end

  return options, args
end

-- simple non-recursive deep-copy function
local function deep_copy(t)
  local cache = { [t] = {} }
  local copy = { { src = t, dst = cache[t] } }

  local function duplicate(v)
    if type(v) == 'table' then
      if not cache[v] then
        cache[v] = {}
        table.insert(copy, { src = v, dst = cache[v] })
      end
      return cache[v]
    end
    return v
  end

  while copy[1] do
    local op = table.remove(copy, 1)
    for k,v in pairs(op.src) do
      op.dst[duplicate(k)] = duplicate(v)
    end
  end

  return cache[t]
end

local function dump(val, key, indent)
  indent = indent or ''
  key = key or ''

  if type(val) == 'table' then
    print(('%s%s = {'):format(indent, key))
    for k,v in pairs(val) do
      dump(v, k, indent .. '  ')
    end
    print(('%s}'):format(indent))
  else
    print(('%s%s = %s'):format(indent, key, tostring(val)))
  end
end

return {
  transform_variadic_args_to_tables = transform_variadic_args_to_tables,
  deep_copy = deep_copy,
  dump = dump,
}
