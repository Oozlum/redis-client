local util = require'redis-client.util'

describe('redis-client.util', function()
  it('dump nominally works', function()
    local print = _G.print
    _G.print = function() end -- we don't actually want to print anything.
    util.dump({ a = 'b' }, 'my table')

    _G.print = print
  end)

  local function do_transform(...)
    local options, args, unwanted = util.transform_variadic_args_to_tables(...)
    return {
      options = options,
      args = args,
      unwanted = unwanted
    }
  end

  it('transforms () => ({},{})', function()
    assert.same(do_transform(), {options = {}, args = {}})
  end)
  it('transforms ({a}) => ({a},{})', function()
    assert.same(do_transform({'a'}), {options = {'a'}, args = {}})
  end)
  it('transforms ({a},x,y,z,...) => ({a},{x,y,z,...})', function()
    assert.same(do_transform({'a'},'x','y','z'), {options = {'a'}, args = {'x','y','z'}})
  end)
  it('transforms ({a},{b},...) => ({a},{b})', function()
    assert.same(do_transform({'a'},{'b'},'x','y','z'), {options = {'a'}, args = {'b'}})
  end)
  it('transforms (x,y,z,...) => ({},{x,y,z,...})', function()
    assert.same(do_transform('x','y','z'), {options = {}, args = {'x','y','z'}})
  end)
  it('transforms (x,{a},...) => ({a},{x,...})', function()
    assert.same(do_transform('x',{'a'},'y','z'), {options = {'a'}, args = {'x','y','z'}})
  end)
  it('transforms (x,{a},{y,z},...) => ({a},{x,y,z})', function()
    assert.same(do_transform('x',{'a'},{'y','z'},'b','c'), {options = {'a'}, args = {'x','y','z'}})
  end)
end)
