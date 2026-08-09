-- Smoke test: proves the harness itself works before anything else is written.
local eq = MiniTest.expect.equality

describe('test harness', function()
  it('runs busted-style cases', function()
    eq(1 + 1, 2)
  end)

  it('has the plugin on the runtimepath', function()
    eq(vim.fn.globpath(vim.o.runtimepath, 'lua/translate/init.lua') ~= '', true)
  end)
end)
