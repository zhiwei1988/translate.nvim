--- Finds the 段落 (Paragraph) under the cursor — the 可译块 whose boundaries come
--- from document structure, not from blank lines (ADR-0001).
local M = {}

--- Structural nodes that are a translatable unit, mapped to the block type the
--- cache uses to pick a key strategy (spec §3.2).
local TRANSLATABLE = {
  paragraph = 'paragraph',
  list = 'list',
  pipe_table = 'table',
  block_quote = 'quote',
  atx_heading = 'heading',
  setext_heading = 'heading',
}

--- Nodes we descend *through* on the way to a block.
local CONTAINER = { document = true, section = true }

--- Tree-sitter ranges are end-exclusive and a block normally stops at column 0
--- of the following line. Convert to the inclusive last line the block occupies.
local function node_lines(node)
  local start_row, _, end_row, end_col = node:range()
  if end_col == 0 and end_row > start_row then
    end_row = end_row - 1
  end
  return start_row, end_row
end

local function get_lines(buf, first, last)
  return vim.api.nvim_buf_get_lines(buf, first, last + 1, false)
end

local function is_blank(line)
  return line == nil or line:match('^%s*$') ~= nil
end

--- Walk outside-in and stop at the *outermost* translatable block containing the
--- row. That single rule produces every §3.1 behaviour: a fenced block nested in
--- a list is reached only after `list`, so the list wins and the code rides
--- along; a fenced block at the top level is reached first, so we refuse.
local function find_block(node, row)
  for child in node:iter_children() do
    if child:named() then
      local first, last = node_lines(child)
      if first <= row and row <= last then
        local block_type = TRANSLATABLE[child:type()]
        if block_type ~= nil then
          return child, block_type
        end
        if CONTAINER[child:type()] then
          return find_block(child, row)
        end
        -- Fenced/indented code, HTML, thematic breaks, front matter, and
        -- anything else we do not recognise: refuse rather than guess.
        return nil, 'untranslatable'
      end
    end
  end
  return nil, 'blank'
end

local function detect_markdown(buf, row)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, 'markdown')
  if not ok or parser == nil then
    return nil, 'no_parser'
  end

  local trees = parser:parse()
  if trees == nil or trees[1] == nil then
    return nil, 'no_parser'
  end

  local node, block_type = find_block(trees[1]:root(), row)
  if node == nil then
    return nil, block_type
  end

  local first, last = node_lines(node)
  local lines = get_lines(buf, first, last)

  -- A loose list carries its trailing blank line inside the node.
  while #lines > 0 and is_blank(lines[#lines]) do
    lines[#lines] = nil
    last = last - 1
  end
  if #lines == 0 or row > last then
    return nil, 'blank'
  end

  return {
    text = table.concat(lines, '\n'),
    block_type = block_type,
    range = { first, last },
  }
end

--- Outside markdown there is no structure to read, so a paragraph degrades to
--- the run of non-blank lines around the cursor.
local function detect_plain(buf, row)
  local total = vim.api.nvim_buf_line_count(buf)
  local function line_at(i)
    return vim.api.nvim_buf_get_lines(buf, i, i + 1, false)[1]
  end

  if row >= total or is_blank(line_at(row)) then
    return nil, 'blank'
  end

  local first, last = row, row
  while first > 0 and not is_blank(line_at(first - 1)) do
    first = first - 1
  end
  while last + 1 < total and not is_blank(line_at(last + 1)) do
    last = last + 1
  end

  return {
    text = table.concat(get_lines(buf, first, last), '\n'),
    block_type = 'plain',
    range = { first, last },
  }
end

--- @param buf integer
--- @param row integer 0-indexed cursor line
--- @param markdown_filetypes string[] filetypes that get the treesitter path
--- @return table|nil paragraph, string|nil reason when nil
function M.paragraph(buf, row, markdown_filetypes)
  local ft = vim.bo[buf].filetype
  if vim.tbl_contains(markdown_filetypes or {}, ft) then
    local block, reason = detect_markdown(buf, row)
    if block ~= nil then
      return block
    end
    -- A missing or broken parser is not a reason to stay silent; degrade to the
    -- plain-text scan (`:checkhealth` is what surfaces the parser problem).
    if reason ~= 'no_parser' then
      return nil, reason
    end
  end
  return detect_plain(buf, row)
end

M.REASONS = {
  untranslatable = '光标落在不可翻译块内（代码块 / HTML 块 / 分隔线），未发起翻译',
  blank = '光标不在任何段落内，未发起翻译',
}

--- Selection translation (CONTEXT.md: 选区翻译). Boundaries come entirely from
--- the user: no block-type judgement, and never widened to whole lines.
--- @param start_pos integer[] {lnum, col} 1-indexed, col in bytes, inclusive
--- @param end_pos integer[] {lnum, col} same
--- @param mode string 'v', 'V' or CTRL-V
function M.selection_from(buf, start_pos, end_pos, mode)
  local s, e = start_pos, end_pos
  if s[1] > e[1] or (s[1] == e[1] and s[2] > e[2]) then
    s, e = e, s
  end

  local first, last = s[1] - 1, e[1] - 1
  local lines = get_lines(buf, first, last)
  if #lines == 0 then
    return nil
  end

  if mode == 'V' then
    -- linewise: columns are meaningless
  elseif mode == '\22' then
    local lo, hi = math.min(s[2], e[2]), math.max(s[2], e[2])
    for i, line in ipairs(lines) do
      lines[i] = line:sub(lo, math.min(hi, #line))
    end
  else
    lines[#lines] = lines[#lines]:sub(1, math.min(e[2], #lines[#lines]))
    lines[1] = lines[1]:sub(s[2])
  end

  local text = table.concat(lines, '\n')
  if text == '' then
    return nil
  end

  return { text = text, block_type = 'selection', range = { first, last } }
end

--- Read the live visual selection. Must be called while still *in* visual mode
--- (the `<Plug>` mapping uses `<Cmd>` precisely so that it is), because the
--- `'<` / `'>` marks do not yet describe the current selection.
function M.selection()
  local mode = vim.fn.mode()
  local buf = vim.api.nvim_get_current_buf()

  if mode == 'v' or mode == 'V' or mode == '\22' then
    local anchor = vim.fn.getpos('v')
    local cursor = vim.fn.getpos('.')
    local start_pos = { anchor[2], anchor[3] }
    local end_pos = { cursor[2], cursor[3] }
    if vim.o.selection == 'exclusive' then
      -- The cursor sits one byte past the last selected byte.
      if end_pos[1] > start_pos[1] or end_pos[2] > start_pos[2] then
        end_pos[2] = math.max(1, end_pos[2] - 1)
      else
        start_pos[2] = math.max(1, start_pos[2] - 1)
      end
    end
    return M.selection_from(buf, start_pos, end_pos, mode)
  end

  local s, e = vim.fn.getpos("'<"), vim.fn.getpos("'>")
  if s[2] == 0 or e[2] == 0 then
    return nil
  end
  return M.selection_from(buf, { s[2], s[3] }, { e[2], e[3] }, vim.fn.visualmode())
end

return M
