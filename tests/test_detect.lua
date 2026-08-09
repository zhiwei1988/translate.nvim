local eq = MiniTest.expect.equality
local detect = require('translate.detect')

--  1 # 标题一          11 (blank)          21 ```
--  2 (blank)           12 | a | b |        22 (blank)
--  3 Prose line one    13 |---|---|        23 Trailing prose.
--  4 prose line two.   14 | 1 | 2 |
--  5 (blank)           15 (blank)
--  6 - item one        16 > quoted line one
--  7 - item two        17 > quoted line two
--  8   - nested a      18 (blank)
--  9   - nested b      19 ```sh
-- 10 - item three      20 echo hi
local FIXTURE = [[
# 标题一

Prose line one
prose line two.

- item one
- item two
  - nested a
  - nested b
- item three

| a | b |
|---|---|
| 1 | 2 |

> quoted line one
> quoted line two

```sh
echo hi
```

Trailing prose.
]]

local buf

--- @param line integer 1-indexed, as a user would name it
local function at(line)
  return detect.paragraph(buf, line - 1, { 'markdown' })
end

local function open(text, filetype)
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
  vim.bo[buf].filetype = filetype
  return buf
end

local function close()
  if buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end

describe('detect.paragraph — markdown structure (§3.1)', function()
  before_each(function()
    open(FIXTURE, 'markdown')
  end)
  after_each(close)

  it('takes a heading as its own block', function()
    local p = at(1)
    eq(p.block_type, 'heading')
    eq(p.text, '# 标题一')
  end)

  it('takes the whole prose block from any of its lines, without blank lines', function()
    for _, line in ipairs({ 3, 4 }) do
      local p = at(line)
      eq(p.block_type, 'paragraph')
      eq(p.text, 'Prose line one\nprose line two.')
    end
  end)

  -- §3.1: a list is one paragraph, nested items included. Translating a single
  -- item would strip it of the context the rest of the list gives it.
  it('takes the entire list from a nested item, not just that item', function()
    local p = at(9) -- "  - nested b"
    eq(p.block_type, 'list')
    eq(p.text, '- item one\n- item two\n  - nested a\n  - nested b\n- item three')
  end)

  it('takes the entire list from a top-level item', function()
    eq(at(6).text, at(9).text)
  end)

  it('takes the whole table from a middle row', function()
    local p = at(13)
    eq(p.block_type, 'table')
    eq(p.text, '| a | b |\n|---|---|\n| 1 | 2 |')
  end)

  it('takes the whole block quote from any of its lines', function()
    local p = at(16)
    eq(p.block_type, 'quote')
    eq(p.text, '> quoted line one\n> quoted line two')
  end)

  it('reports 0-indexed inclusive ranges', function()
    eq(at(3).range, { 2, 3 })
    eq(at(9).range, { 5, 9 })
  end)

  it('takes the prose after a fenced block', function()
    local p = at(23)
    eq(p.block_type, 'paragraph')
    eq(p.text, 'Trailing prose.')
  end)
end)

describe('detect.paragraph — untranslatable blocks (§3.1)', function()
  after_each(close)

  -- Silently translating the neighbouring paragraph is more confusing than
  -- doing nothing at all, so there is no search for a nearby block.
  it('refuses a fenced code block rather than reaching for a neighbour', function()
    open(FIXTURE, 'markdown')
    local p, reason = at(20) -- "echo hi"
    eq(p, nil)
    eq(reason, 'untranslatable')
  end)

  it('refuses the fence line itself', function()
    open(FIXTURE, 'markdown')
    eq(select(2, at(19)), 'untranslatable')
  end)

  it('refuses an indented code block', function()
    open('Prose.\n\n    indented code\n    more code\n\nMore prose.\n', 'markdown')
    eq(select(2, at(3)), 'untranslatable')
  end)

  it('refuses an HTML block', function()
    open('Prose.\n\n<div>\n  raw html\n</div>\n\nMore prose.\n', 'markdown')
    eq(select(2, at(3)), 'untranslatable')
  end)

  it('refuses a thematic break', function()
    open('Prose.\n\n---\n\nMore prose.\n', 'markdown')
    eq(select(2, at(3)), 'untranslatable')
  end)

  it('refuses YAML front matter', function()
    open('---\ntitle: hi\n---\n\nProse.\n', 'markdown')
    eq(select(2, at(2)), 'untranslatable')
  end)

  it('refuses a blank line between blocks', function()
    open(FIXTURE, 'markdown')
    eq(select(2, at(2)), 'blank')
  end)
end)

describe('detect.paragraph — code inside a list (§3.1)', function()
  after_each(close)

  -- The fenced block rides along with the list; keeping it untranslated is left
  -- to system prompt rule 4, which has no code-level backstop — hence this test.
  it('still reports the list, with the fenced block included in its text', function()
    open('- step one\n\n  ```lua\n  local x = 1\n  ```\n\n- step two\n', 'markdown')
    local p = at(4) -- inside the fenced block
    eq(p.block_type, 'list')
    eq(p.text:find('local x = 1', 1, true) ~= nil, true)
    eq(p.text:find('step one', 1, true) ~= nil, true)
    eq(p.text:find('step two', 1, true) ~= nil, true)
  end)
end)

describe('detect.paragraph — non-markdown falls back to blank-line scanning (§3.1)', function()
  after_each(close)

  it('takes the run of non-blank lines around the cursor', function()
    open('first block line a\nfirst block line b\n\nsecond block\n', 'text')
    local p = at(2)
    eq(p.block_type, 'plain')
    eq(p.text, 'first block line a\nfirst block line b')
    eq(p.range, { 0, 1 })
  end)

  it('refuses a blank line', function()
    open('a\n\nb\n', 'text')
    eq(select(2, at(2)), 'blank')
  end)

  -- A `#` comment in python is a comment, not an ATX heading: no structure
  -- parsing runs at all outside markdown_filetypes.
  it('does not read a python "#" comment as a heading', function()
    open('# a comment\ncode_line = 1\n\nother = 2\n', 'python')
    local p = at(1)
    eq(p.block_type, 'plain')
    eq(p.text, '# a comment\ncode_line = 1')
  end)

  it('treats a markdown file as plain text when it is not in markdown_filetypes', function()
    open(FIXTURE, 'markdown')
    local p = detect.paragraph(buf, 6, { 'vimwiki' })
    eq(p.block_type, 'plain')
  end)
end)

describe('detect.selection — visual (§3.3)', function()
  after_each(close)

  it('takes exactly the selected columns without widening to whole lines', function()
    open('hello brave new world\n', 'text')
    -- "brave new" is bytes 7..15, 1-indexed inclusive
    local sel = detect.selection_from(buf, { 1, 7 }, { 1, 15 }, 'v')
    eq(sel.text, 'brave new')
    eq(sel.block_type, 'selection')
    eq(sel.range, { 0, 0 })
  end)

  it('spans lines while still honouring the end column', function()
    open('alpha beta\ngamma delta\n', 'text')
    local sel = detect.selection_from(buf, { 1, 7 }, { 2, 5 }, 'v')
    eq(sel.text, 'beta\ngamma')
    eq(sel.range, { 0, 1 })
  end)

  it('normalizes a backwards selection', function()
    open('hello brave new world\n', 'text')
    eq(detect.selection_from(buf, { 1, 15 }, { 1, 7 }, 'v').text, 'brave new')
  end)

  it('takes whole lines for a linewise selection', function()
    open('alpha beta\ngamma delta\n', 'text')
    eq(detect.selection_from(buf, { 1, 3 }, { 2, 2 }, 'V').text, 'alpha beta\ngamma delta')
  end)

  it('indexes columns by byte so multibyte prefixes do not shift the cut', function()
    open('前言 brave 后记\n', 'text')
    local sel = detect.selection_from(buf, { 1, #'前言 ' + 1 }, { 1, #'前言 brave' }, 'v')
    eq(sel.text, 'brave')
  end)

  it('clamps an end column past the end of the line', function()
    open('short\n', 'text')
    eq(detect.selection_from(buf, { 1, 1 }, { 1, 2147483647 }, 'v').text, 'short')
  end)

  it('returns nil for an empty selection', function()
    open('\n', 'text')
    eq(detect.selection_from(buf, { 1, 1 }, { 1, 1 }, 'v'), nil)
  end)
end)
