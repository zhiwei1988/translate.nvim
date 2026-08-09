local eq = MiniTest.expect.equality
local neq = MiniTest.expect.no_equality
local float = require('translate.float')

local src_buf, src_win, inst, saved

local LONG = {}
for i = 1, 60 do
  LONG[i] = ('译文第 %d 行，这一行足够长以便触发折行与溢出判断。'):format(i)
end

local function paragraph_lines(n, width)
  local lines = {}
  for i = 1, n do
    lines[i] = string.rep('x', width or 40) .. i
  end
  return lines
end

local function open(over)
  inst = float.open(vim.tbl_extend('force', {
    win = src_win,
    buf = src_buf,
    range = { 0, 1 },
    provider = 'deepseek',
    model = 'deepseek-v4-flash',
    max_height = 0.5,
    keymaps = { scroll_down = '<C-d>', scroll_up = '<C-u>', close = '<Esc>' },
  }, over or {}))
  return inst
end

local function config()
  return vim.api.nvim_win_get_config(inst.win)
end

local function float_lines()
  return vim.api.nvim_buf_get_lines(inst.buf, 0, -1, false)
end

local function has_map(buf, lhs)
  local want = vim.keycode(lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if vim.keycode(m.lhs) == want then
      return true
    end
  end
  return false
end

local function footer_text()
  local chunks = config().footer
  if chunks == nil then
    return ''
  end
  return table.concat(vim.tbl_map(function(c)
    return c[1]
  end, chunks))
end

local function topline()
  return vim.api.nvim_win_call(inst.win, function()
    return vim.fn.line('w0')
  end)
end

describe('float', function()
  before_each(function()
    saved = { lines = vim.o.lines, columns = vim.o.columns }
    vim.o.lines, vim.o.columns = 40, 100

    src_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(src_buf, 0, -1, false, paragraph_lines(30))
    src_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(src_win, src_buf)
    vim.api.nvim_win_set_cursor(src_win, { 1, 0 })
    vim.cmd('redraw')
  end)

  after_each(function()
    if inst ~= nil then
      inst:close()
      inst = nil
    end
    if vim.api.nvim_buf_is_valid(src_buf) then
      vim.api.nvim_buf_delete(src_buf, { force = true })
    end
    vim.o.lines, vim.o.columns = saved.lines, saved.columns
  end)

  describe('placement (§7.1)', function()
    it('anchors under the last line of the paragraph so the source stays visible', function()
      open({ range = { 0, 1 } })
      local c = config()
      eq(c.relative, 'win')
      eq(c.anchor, 'NW')
      eq(c.bufpos, { 1, 0 })
      eq(c.row, 1)
      eq(c.col, 0)
    end)

    it('flips above the paragraph when there is no room below', function()
      vim.api.nvim_win_set_cursor(src_win, { 29, 0 })
      vim.cmd('normal! zb')
      vim.cmd('redraw')
      open({ range = { 27, 28 } })
      inst:set_text(table.concat(LONG, '\n'))

      local c = config()
      eq(c.anchor, 'SW')
      eq(c.bufpos, { 27, 0 })
      eq(c.row, 0)
    end)

    -- Scrolling the source out from under the reader is the most disorienting
    -- thing the plugin could do, so a short window is accepted instead.
    it('never scrolls the source window to make room', function()
      vim.api.nvim_win_set_cursor(src_win, { 29, 0 })
      vim.cmd('normal! zb')
      vim.cmd('redraw')
      local view = vim.fn.winsaveview()
      open({ range = { 27, 28 } })
      inst:set_text(table.concat(LONG, '\n'))
      eq(vim.fn.winsaveview().topline, view.topline)
    end)

    it('takes its width from the widest line of the paragraph', function()
      vim.api.nvim_buf_set_lines(src_buf, 0, -1, false, paragraph_lines(30, 52))
      open({ range = { 0, 1 } })
      eq(config().width, 53)
    end)

    it('never goes narrower than 20 columns', function()
      vim.api.nvim_buf_set_lines(src_buf, 0, -1, false, { 'ab', 'cd', 'ef' })
      open({ range = { 0, 1 } })
      eq(config().width, 20)
    end)

    it('never goes wider than the editor minus a margin', function()
      vim.api.nvim_buf_set_lines(src_buf, 0, -1, false, { string.rep('y', 300), 'b' })
      open({ range = { 0, 1 } })
      eq(config().width, vim.o.columns - 8)
    end)
  end)

  describe('sizing (§7.1)', function()
    it('starts small and grows with the content', function()
      open()
      local start = config().height
      inst:append('一行\n二行\n三行\n四行\n五行\n六行')
      eq(config().height > start, true)
    end)

    it('stops growing at the max_height fraction of the editor', function()
      open({ max_height = 0.5 })
      inst:set_text(table.concat(LONG, '\n'))
      eq(config().height, 20)
    end)

    it('accepts an absolute max_height', function()
      open({ max_height = 7 })
      inst:set_text(table.concat(LONG, '\n'))
      eq(config().height, 7)
    end)

    -- Resizing on every token makes the window jitter continuously.
    it('does not resize when a delta does not add a wrapped line', function()
      open()
      inst:append('短')
      local before = config().height
      inst:append('文')
      eq(config().height, before)
    end)
  end)

  describe('focus (ADR-0002)', function()
    it('never takes focus when it opens', function()
      open()
      eq(vim.api.nvim_get_current_win(), src_win)
    end)

    it('leaves the cursor in the source buffer while streaming', function()
      open()
      local cursor = vim.api.nvim_win_get_cursor(src_win)
      for _ = 1, 30 do
        inst:append('更多译文内容\n')
      end
      eq(vim.api.nvim_get_current_win(), src_win)
      eq(vim.api.nvim_win_get_cursor(src_win), cursor)
    end)

    it('is created as a non-focusable window', function()
      open()
      eq(config().focusable, false)
    end)
  end)

  describe('content', function()
    it('renders streamed deltas as they arrive', function()
      open()
      inst:append('你好')
      inst:append('，世界')
      eq(float_lines(), { '你好，世界' })
    end)

    it('splits deltas that contain newlines', function()
      open()
      inst:append('第一行\n第二')
      inst:append('行')
      eq(float_lines(), { '第一行', '第二行' })
    end)

    -- Reading starts at the first line; tail-following would scroll it away
    -- within seconds (§7.2).
    it('keeps the viewport pinned to the top while streaming', function()
      open()
      inst:set_text(table.concat(LONG, '\n'))
      eq(topline(), 1)
    end)

    it('marks the float buffer so users can hang their own autocmds on it', function()
      open()
      eq(vim.bo[inst.buf].filetype, 'translate-float')
    end)

    it('highlights the source paragraph while translating and clears it on close', function()
      open({ range = { 0, 1 } })
      local ns = float.namespace()
      eq(#vim.api.nvim_buf_get_extmarks(src_buf, ns, 0, -1, {}) > 0, true)
      inst:close()
      eq(vim.api.nvim_buf_get_extmarks(src_buf, ns, 0, -1, {}), {})
    end)
  end)

  describe('title and footer (§7.2)', function()
    it('shows the provider and model', function()
      open()
      local title = config().title[1][1]
      eq(title:find('deepseek', 1, true) ~= nil, true)
      eq(title:find('deepseek-v4-flash', 1, true) ~= nil, true)
    end)

    it('marks a cache hit with a lightning bolt', function()
      open()
      inst:set_text('你好')
      inst:mark_cached()
      eq(config().title[1][1]:find('⚡', 1, true) ~= nil, true)
    end)

    it('marks a rewritten fenced block with a warning sign', function()
      open()
      inst:set_text('你好')
      inst:mark_fence_mismatch()
      eq(config().title[1][1]:find('⚠', 1, true) ~= nil, true)
    end)

    it('marks a failure with a cross', function()
      open()
      inst:fail({ class = 'auth', message = '401 Unauthorized', hint = '检查 DEEPSEEK_API_KEY' })
      eq(config().title[1][1]:find('✖', 1, true) ~= nil, true)
    end)

    it('spins while loading and stops when the stream finishes', function()
      open()
      local spinning = config().title[1][1]
      inst:append('你好')
      inst:finish()
      neq(config().title[1][1], spinning)
      eq(config().title[1][1]:find('⠋', 1, true), nil)
    end)

    it('offers a footer only while content sits below the viewport', function()
      open()
      inst:set_text('一行译文')
      eq(footer_text(), '')

      inst:set_text(table.concat(LONG, '\n'))
      eq(footer_text():find('↓', 1, true) ~= nil, true)
      eq(config().footer_pos, 'right')
    end)

    -- The indicator has to *disappear*, which means clearing it explicitly:
    -- leaving the key unset keeps whatever was drawn last.
    it('drops the footer once the reader reaches the bottom', function()
      open()
      inst:set_text(table.concat(LONG, '\n'))
      eq(footer_text() ~= '', true)
      inst:scroll(1000) -- clamps at the last full screen
      eq(footer_text(), '')
    end)

    it('does not scroll past the last screenful', function()
      open()
      inst:set_text(table.concat(LONG, '\n'))
      inst:scroll(1000)
      local bottom = topline()
      inst:scroll(1000)
      eq(topline(), bottom)
    end)
  end)

  describe('error state (§7.2)', function()
    it('renders the failure in the window in plain language', function()
      open()
      inst:fail({ class = 'auth', message = '401 Unauthorized', hint = 'DEEPSEEK_API_KEY 无效或未设置。' })
      local text = table.concat(float_lines(), '\n')
      eq(text:find('401 Unauthorized', 1, true) ~= nil, true)
      eq(text:find('DEEPSEEK_API_KEY', 1, true) ~= nil, true)
    end)

    -- Retrying is off the table once text is on screen, so the error joins it
    -- rather than replacing it (§6.8).
    it('appends the failure below the translation already rendered', function()
      open()
      inst:append('已经翻好的前半段')
      inst:fail({ class = 'server', message = '502 Bad Gateway' })
      local text = table.concat(float_lines(), '\n')
      eq(text:find('已经翻好的前半段', 1, true) ~= nil, true)
      eq(text:find('502 Bad Gateway', 1, true) ~= nil, true)
    end)
  end)

  describe('scrolling keymaps (§7.4)', function()
    it('binds nothing while the translation fits', function()
      open()
      inst:set_text('短短一行')
      eq(has_map(src_buf, '<C-d>'), false)
      eq(has_map(src_buf, '<C-u>'), false)
    end)

    -- Dynamic: the content only starts overflowing partway through the stream,
    -- and the binding has to appear at that moment.
    it('binds at the moment streaming content first overflows', function()
      open()
      inst:append('第一行\n')
      eq(has_map(src_buf, '<C-d>'), false)
      inst:append(table.concat(LONG, '\n'))
      eq(has_map(src_buf, '<C-d>'), true)
    end)

    it('scrolls the float viewport without moving the cursor or closing', function()
      open()
      inst:set_text(table.concat(LONG, '\n'))
      local cursor = vim.api.nvim_win_get_cursor(src_win)

      vim.api.nvim_feedkeys(vim.keycode('<C-d>'), 'x', false)

      eq(vim.api.nvim_win_get_cursor(src_win), cursor)
      eq(topline() > 1, true)
      eq(inst:is_open(), true)
      eq(vim.api.nvim_get_current_win(), src_win)
    end)

    it('scrolls back up again', function()
      open()
      inst:set_text(table.concat(LONG, '\n'))
      vim.api.nvim_feedkeys(vim.keycode('<C-d>'), 'x', false)
      local scrolled = topline()
      vim.api.nvim_feedkeys(vim.keycode('<C-u>'), 'x', false)
      eq(topline() < scrolled, true)
    end)

    it('closes on the close key', function()
      open()
      inst:set_text(table.concat(LONG, '\n'))
      vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'x', false)
      eq(inst:is_open(), false)
    end)

    -- <C-e>/<C-y> already work without closing the float, so hijacking them
    -- would be a pure loss; `q` is the macro prefix.
    it('leaves <C-e>, <C-y> and q alone', function()
      open()
      inst:set_text(table.concat(LONG, '\n'))
      eq(has_map(src_buf, '<C-e>'), false)
      eq(has_map(src_buf, '<C-y>'), false)
      eq(has_map(src_buf, 'q'), false)
      eq(has_map(src_buf, 'gg'), false)
      eq(has_map(src_buf, '<C-f>'), false)
    end)

    it('honours a keymap disabled with false', function()
      open({ keymaps = { scroll_down = false, scroll_up = '<C-u>', close = '<Esc>' } })
      inst:set_text(table.concat(LONG, '\n'))
      eq(has_map(src_buf, '<C-d>'), false)
      eq(has_map(src_buf, '<C-u>'), true)
    end)

    -- Any path that closes the window while leaving a mapping behind puts a
    -- ghost key in the user's own buffer.
    it('leaves no mapping behind after closing', function()
      open()
      inst:set_text(table.concat(LONG, '\n'))
      eq(has_map(src_buf, '<C-d>'), true)
      inst:close()
      eq(has_map(src_buf, '<C-d>'), false)
      eq(has_map(src_buf, '<C-u>'), false)
      eq(has_map(src_buf, '<Esc>'), false)
    end)

    it('restores a buffer-local mapping it had to shadow', function()
      vim.keymap.set('n', '<C-d>', 'ihijacked', { buffer = src_buf })
      open()
      inst:set_text(table.concat(LONG, '\n'))
      inst:close()

      local restored
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(src_buf, 'n')) do
        if vim.keycode(m.lhs) == vim.keycode('<C-d>') then
          restored = m.rhs
        end
      end
      eq(restored, 'ihijacked')
    end)

    -- Any route that destroys the window without going through close() would
    -- otherwise strand <C-d>/<C-u>/<Esc> in the user's own document.
    it('leaves no mapping behind when the window is closed from outside', function()
      open()
      inst:set_text(table.concat(LONG, '\n'))
      eq(has_map(src_buf, '<C-d>'), true)

      vim.api.nvim_win_close(inst.win, true)
      vim.api.nvim_exec_autocmds('WinClosed', { pattern = tostring(inst.win) })

      eq(has_map(src_buf, '<C-d>'), false)
      eq(has_map(src_buf, '<Esc>'), false)
    end)

    it('leaves no mapping behind when the cursor leaves the paragraph', function()
      open({ range = { 0, 1 } })
      inst:set_text(table.concat(LONG, '\n'))
      eq(has_map(src_buf, '<C-d>'), true)

      vim.api.nvim_win_set_cursor(src_win, { 6, 0 })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = src_buf })

      eq(has_map(src_buf, '<C-d>'), false)
    end)

    it('is safe to close twice', function()
      open()
      inst:close()
      inst:close()
      eq(inst:is_open(), false)
    end)
  end)

  describe('closing on cursor movement (§7.3)', function()
    it('stays open while the cursor moves inside the paragraph', function()
      open({ range = { 0, 4 } })
      for _, line in ipairs({ 2, 3, 5 }) do
        vim.api.nvim_win_set_cursor(src_win, { line, 0 })
        vim.api.nvim_exec_autocmds('CursorMoved', { buffer = src_buf })
        eq(inst:is_open(), true)
      end
    end)

    it('closes when the cursor leaves the paragraph', function()
      open({ range = { 0, 4 } })
      vim.api.nvim_win_set_cursor(src_win, { 6, 0 })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = src_buf })
      eq(inst:is_open(), false)
    end)

    it('reports closing through on_close exactly once', function()
      local closes = 0
      open({
        range = { 0, 4 },
        on_close = function()
          closes = closes + 1
        end,
      })
      vim.api.nvim_win_set_cursor(src_win, { 6, 0 })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = src_buf })
      inst:close()
      eq(closes, 1)
    end)

    it('cleans up when the source buffer goes away', function()
      open()
      vim.api.nvim_buf_delete(src_buf, { force = true })
      eq(inst:is_open(), false)
    end)
  end)
end)
