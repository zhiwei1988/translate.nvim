-- Headless entry point. A *collection* error (e.g. a syntax error or a missing
-- module in a test file) otherwise leaves nvim sitting at a "Press ENTER"
-- prompt forever, which hangs CI instead of failing it.
local file = vim.env.TEST_FILE

local ok, err = pcall(function()
  if file and file ~= '' then
    MiniTest.run_file(file)
  else
    MiniTest.run()
  end
end)

if not ok then
  io.stderr:write('\ntest run failed to collect or execute:\n' .. tostring(err) .. '\n')
  vim.cmd('silent! 1cquit')
end
