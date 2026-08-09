-- Minimal init for headless test runs. Keeps the user's own config out entirely.
local root = vim.fn.fnamemodify(vim.fn.resolve(vim.fn.expand('<sfile>:p')), ':h:h')

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. '/deps/mini.nvim')
vim.opt.packpath = { root .. '/deps' }

vim.g.translate_test_root = root

require('mini.test').setup({
  collect = {
    -- `describe` / `it` instead of mini.test's own set/case vocabulary.
    emulate_busted = true,
    find_files = function()
      return vim.fn.globpath(root .. '/tests', 'test_*.lua', true, true)
    end,
  },
})
