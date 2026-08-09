if vim.g.loaded_translate then
  return
end
vim.g.loaded_translate = true

-- No default global keys: any default collides with somebody's configuration.
-- Users map these themselves (spec §9.2).
vim.keymap.set('n', '<Plug>(translate)', function()
  require('translate').translate()
end, { desc = '翻译光标所在段落' })

-- `<Cmd>` on purpose: it runs without leaving visual mode, so `getpos('v')`
-- still describes *this* selection. A plain function mapping would fire while
-- `'<` / `'>` still hold the previous one, and §3.3 needs exact columns.
vim.keymap.set(
  'x',
  '<Plug>(translate-selection)',
  '<Cmd>lua require("translate").translate_selection()<CR>',
  { desc = '翻译 visual 选区' }
)

require('translate.commands').setup()
