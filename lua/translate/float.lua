--- 悬浮译文窗 (Translation Float).
---
--- It never takes focus: the cursor stays in the source text, and whether the
--- window is open is decided solely by whether the cursor is still inside the
--- paragraph (ADR-0002). That is what makes "scroll inside the float" impossible
--- by construction, and why long translations are paged with temporary mappings
--- on the *source* buffer instead.
local M = {}

local uv = vim.uv or vim.loop

local NS = vim.api.nvim_create_namespace('translate.source')
local SPINNER = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local SPINNER_INTERVAL = 100

local MIN_WIDTH = 20
local WIDTH_MARGIN = 8
local BORDER_ROWS = 2

function M.namespace()
  return NS
end

local function define_highlights()
  local hl = vim.api.nvim_set_hl
  hl(0, 'TranslateBorder', { link = 'FloatBorder', default = true })
  -- Amber and red without hardcoding a palette: every colorscheme defines these.
  hl(0, 'TranslateBorderLoading', { link = 'DiagnosticWarn', default = true })
  hl(0, 'TranslateBorderError', { link = 'DiagnosticError', default = true })
  hl(0, 'TranslateTitle', { link = 'FloatTitle', default = true })
  hl(0, 'TranslateSource', { link = 'Visual', default = true })
end

local function display_rows(lines, width)
  local rows = 0
  for _, line in ipairs(lines) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  return rows
end

local function resolve_max_height(max_height)
  if max_height > 0 and max_height < 1 then
    return math.max(1, math.floor(vim.o.lines * max_height))
  end
  return math.max(1, math.floor(max_height))
end

local Float = {}
Float.__index = Float

--- Width follows the paragraph, so the translation sits in a column the reader's
--- eye is already scanning.
local function paragraph_width(buf, range)
  local width = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, range[1], range[2] + 1, false)) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return math.max(MIN_WIDTH, math.min(width, vim.o.columns - WIDTH_MARGIN))
end

--- Rows available under / over the paragraph, border included.
local function available(win, range)
  local below_of = vim.fn.screenpos(win, range[2] + 1, 1).row
  local above_of = vim.fn.screenpos(win, range[1] + 1, 1).row
  local bottom = vim.o.lines - vim.o.cmdheight - 1

  return {
    below = below_of > 0 and (bottom - below_of - BORDER_ROWS) or 0,
    above = above_of > 0 and (above_of - 1 - BORDER_ROWS) or 0,
  }
end

function Float:_geometry()
  local wanted = math.max(1, display_rows(self.lines, self.width))
  local capped = math.min(wanted, resolve_max_height(self.max_height))
  local space = available(self.src_win, self.range)

  -- Below by preference; flip above only when that is genuinely roomier. When
  -- neither side fits, take the larger and accept a short window — §7.4's
  -- scrolling is what makes that survivable.
  local below = space.below >= capped or space.below >= space.above
  local room = below and space.below or space.above

  return {
    height = math.max(1, math.min(capped, math.max(room, 1))),
    anchor = below and 'NW' or 'SW',
    bufpos = below and { self.range[2], 0 } or { self.range[1], 0 },
    row = below and 1 or 0,
  }
end

function Float:_title()
  local parts = {}
  if self.state == 'loading' then
    parts[#parts + 1] = SPINNER[self.spinner_frame]
  elseif self.state == 'error' then
    parts[#parts + 1] = '✖'
  end
  if self.cached then
    parts[#parts + 1] = '⚡'
  end
  if self.fence_mismatch then
    parts[#parts + 1] = '⚠'
  end
  parts[#parts + 1] = ('%s · %s'):format(self.provider, self.model)
  return (' %s '):format(table.concat(parts, ' '))
end

--- Rows still below the viewport. Tracked from `self.topline` rather than read
--- back with `line('w$')`, because re-anchoring the window resets the view and
--- the answer would depend on whether a redraw happened to have run.
function Float:_rows_below()
  local from_top = display_rows(vim.list_slice(self.lines, self.topline, #self.lines), self.width)
  return math.max(0, from_top - self.height)
end

--- `↓ 还有 N 行`, and only while something is actually below the viewport.
--- During streaming this number climbs on its own, which doubles as a free
--- sense of progress (§7.2).
function Float:_footer()
  local rest = self:_rows_below()
  if rest <= 0 then
    return nil
  end
  return (' ↓ 还有 %d 行 '):format(rest)
end

function Float:_border_hl()
  if self.state == 'error' then
    return 'TranslateBorderError'
  elseif self.state == 'loading' then
    return 'TranslateBorderLoading'
  end
  return 'TranslateBorder'
end

function Float:_refresh_config(force_geometry)
  if not self:is_open() then
    return
  end

  local geometry = self:_geometry()
  local config = {
    relative = 'win',
    win = self.src_win,
    anchor = geometry.anchor,
    bufpos = geometry.bufpos,
    row = geometry.row,
    col = 0,
    width = self.width,
    height = geometry.height,
    style = 'minimal',
    border = 'rounded',
    focusable = false,
    title = self:_title(),
    title_pos = 'left',
    zindex = 60,
  }

  -- Always assigned: omitting the key leaves the previous footer on screen, so
  -- the indicator would never disappear once it had appeared.
  config.footer = self:_footer() or ''
  config.footer_pos = 'right'

  -- Only touch geometry when the wrapped line count actually moved, otherwise
  -- the window twitches on every token (§7.1).
  if not force_geometry and geometry.height == self.height and geometry.anchor == self.anchor then
    config.width, config.height = self.width, self.height
  end

  self.height, self.anchor = config.height, config.anchor
  vim.api.nvim_win_set_config(self.win, config)

  -- Re-anchoring resets the view, so the viewport we are tracking has to be put
  -- back afterwards.
  self:_apply_topline()

  vim.api.nvim_set_option_value(
    'winhighlight',
    ('FloatBorder:%s,FloatTitle:TranslateTitle,FloatFooter:TranslateTitle'):format(self:_border_hl()),
    { win = self.win }
  )
end

function Float:_render()
  if not self:is_open() then
    return
  end

  local before = self.height
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, self.lines)
  vim.bo[self.buf].modifiable = false

  self:_refresh_config(false)
  self:_sync_keymaps()

  if before ~= self.height then
    self:_refresh_config(true)
  end
end

--- Bind only while the translation genuinely overflows. The argument for
--- hijacking <C-d> — that its normal meaning would take the cursor out of the
--- paragraph and close the window anyway — only holds when there is something
--- to scroll; below that, hijacking just hands the user a dead key (§7.4).
function Float:_sync_keymaps()
  local overflowing = self:is_open() and display_rows(self.lines, self.width) > self.height
  if overflowing == self.mapped then
    return
  end
  self.mapped = overflowing

  if overflowing then
    self:_bind('scroll_down', function()
      self:scroll(math.max(1, math.floor(self.height / 2)))
    end)
    self:_bind('scroll_up', function()
      self:scroll(-math.max(1, math.floor(self.height / 2)))
    end)
    self:_bind('close', function()
      self:close()
    end)
  else
    self:_unbind()
  end
end

function Float:_bind(name, fn)
  local lhs = self.keymaps[name]
  if lhs == nil or lhs == false then
    return
  end

  -- Remember anything of the user's we are shadowing, so closing puts their
  -- buffer back exactly as it was. `maparg(..., true)` returns the dict shape
  -- `mapset()` consumes; nvim_buf_get_keymap's does not round-trip.
  vim.api.nvim_buf_call(self.src_buf, function()
    local previous = vim.fn.maparg(lhs, 'n', false, true)
    if type(previous) == 'table' and previous.buffer == 1 then
      self.shadowed[lhs] = previous
    end
  end)

  vim.keymap.set('n', lhs, fn, { buffer = self.src_buf, nowait = true, desc = 'translate.nvim: 悬浮译文窗' })
  self.bound[lhs] = true
end

function Float:_unbind()
  for lhs in pairs(self.bound) do
    pcall(vim.keymap.del, 'n', lhs, { buffer = self.src_buf })

    local previous = self.shadowed[lhs]
    if previous ~= nil then
      vim.api.nvim_buf_call(self.src_buf, function()
        pcall(vim.fn.mapset, 'n', 0, previous)
      end)
    end
  end
  self.bound = {}
  self.shadowed = {}
  self.mapped = false
end

function Float:_apply_topline()
  if not self:is_open() then
    return
  end
  local top = math.max(1, math.min(self.topline, #self.lines))
  vim.api.nvim_win_call(self.win, function()
    vim.fn.winrestview({ topline = top, lnum = top, col = 0, leftcol = 0, curswant = 0 })
  end)
end

--- Furthest line that can sit at the top while still filling the window.
function Float:_max_topline()
  local rows = 0
  for i = #self.lines, 1, -1 do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(self.lines[i]) / self.width))
    if rows >= self.height then
      return i
    end
  end
  return 1
end

--- Move the float's viewport with the cursor untouched — the whole reason the
--- source-buffer mappings can exist at all.
--- @param rows integer display rows; wrapped lines are stepped over correctly
function Float:scroll(rows)
  if not self:is_open() or rows == 0 then
    return
  end

  local step = rows > 0 and 1 or -1
  local remaining = math.abs(rows)
  local top = self.topline

  while remaining > 0 do
    local next_top = top + step
    if next_top < 1 or next_top > #self.lines then
      break
    end
    local crossed = step > 0 and top or next_top
    remaining = remaining - math.max(1, math.ceil(vim.fn.strdisplaywidth(self.lines[crossed]) / self.width))
    top = next_top
  end

  self.topline = math.max(1, math.min(top, self:_max_topline()))
  self:_apply_topline()
  self:_refresh_config(true)
end

function Float:append(delta)
  self.text = self.text .. delta
  self.lines = vim.split(self.text, '\n', { plain = true })
  self:_render()
end

--- Whole-cloth render: a cache hit, or the accumulated text replayed when the
--- reader returns to a paragraph mid-flight.
function Float:set_text(text)
  self.text = text
  self.lines = vim.split(self.text, '\n', { plain = true })
  self:_render()
end

function Float:mark_cached()
  self.cached = true
  self.state = 'idle'
  self:_stop_spinner()
  self:_refresh_config(true)
end

function Float:mark_fence_mismatch()
  self.fence_mismatch = true
  self:_refresh_config(true)
end

function Float:finish()
  self.state = 'idle'
  self:_stop_spinner()
  self:_refresh_config(true)
end

--- Errors join the translation rather than replacing it: the text already on
--- screen was paid for, and wiping it would be worse than saying what broke.
function Float:fail(err)
  self.state = 'error'
  self:_stop_spinner()

  local message = require('translate.errors').format(err)

  if self.text ~= '' then
    self.text = self.text .. '\n\n' .. message
  else
    self.text = message
  end
  self.lines = vim.split(self.text, '\n', { plain = true })
  self:_render()
  self:_refresh_config(true)
end

function Float:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

function Float:_stop_spinner()
  if self.spinner_timer ~= nil then
    self.spinner_timer:stop()
    if not self.spinner_timer:is_closing() then
      self.spinner_timer:close()
    end
    self.spinner_timer = nil
  end
end

function Float:close()
  if self.closed then
    return
  end
  self.closed = true

  self:_stop_spinner()
  self:_unbind()

  if self.augroup ~= nil then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end

  if vim.api.nvim_buf_is_valid(self.src_buf) then
    vim.api.nvim_buf_clear_namespace(self.src_buf, NS, 0, -1)
  end

  if self:is_open() then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  self.win = nil

  if self.buf ~= nil and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end

  if self.on_close ~= nil then
    self.on_close()
    self.on_close = nil
  end
end

--- @param opts table win, buf, range, provider, model, max_height, keymaps, on_close
function M.open(opts)
  define_highlights()

  local self = setmetatable({
    src_win = opts.win,
    src_buf = opts.buf,
    range = opts.range,
    provider = opts.provider,
    model = opts.model,
    max_height = opts.max_height or 0.5,
    keymaps = opts.keymaps or {},
    on_close = opts.on_close,

    text = '',
    lines = { '' },
    state = 'loading',
    cached = false,
    fence_mismatch = false,
    spinner_frame = 1,
    -- Reading starts at line one and stays there: no tail-follow (§7.2).
    topline = 1,
    bound = {},
    shadowed = {},
    mapped = false,
    closed = false,
  }, Float)

  self.width = paragraph_width(self.src_buf, self.range)
  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].bufhidden = 'wipe'
  -- Not for the plugin's benefit — it maps nothing here — but so users can hang
  -- their own FileType autocmds and highlight rules on it (§7.4).
  vim.bo[self.buf].filetype = 'translate-float'
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { '⠋ 翻译中…' })
  vim.bo[self.buf].modifiable = false

  local geometry = self:_geometry()
  self.height, self.anchor = geometry.height, geometry.anchor

  self.win = vim.api.nvim_open_win(self.buf, false, {
    relative = 'win',
    win = self.src_win,
    anchor = geometry.anchor,
    bufpos = geometry.bufpos,
    row = geometry.row,
    col = 0,
    width = self.width,
    height = geometry.height,
    style = 'minimal',
    border = 'rounded',
    -- Never focusable: §7.3 would close the window the instant the cursor
    -- entered it anyway.
    focusable = false,
    noautocmd = true,
    title = self:_title(),
    title_pos = 'left',
    zindex = 60,
  })

  vim.wo[self.win].wrap = true
  vim.wo[self.win].linebreak = true
  vim.wo[self.win].cursorline = false
  vim.api.nvim_set_option_value(
    'winhighlight',
    ('FloatBorder:%s,FloatTitle:TranslateTitle,FloatFooter:TranslateTitle'):format(self:_border_hl()),
    { win = self.win }
  )

  vim.api.nvim_buf_set_extmark(self.src_buf, NS, self.range[1], 0, {
    end_row = self.range[2],
    end_col = #(vim.api.nvim_buf_get_lines(self.src_buf, self.range[2], self.range[2] + 1, false)[1] or ''),
    hl_group = 'TranslateSource',
  })

  self.augroup = vim.api.nvim_create_augroup(('translate_float_%d'):format(self.buf), { clear = true })

  -- Moving *within* the paragraph keeps the window; leaving the range closes it.
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = self.augroup,
    buffer = self.src_buf,
    callback = function()
      local line = vim.api.nvim_win_get_cursor(self.src_win)[1] - 1
      if line < self.range[1] or line > self.range[2] then
        self:close()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    group = self.augroup,
    buffer = self.src_buf,
    callback = function()
      self:close()
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufLeave', 'WinLeave' }, {
    group = self.augroup,
    buffer = self.src_buf,
    callback = function()
      self:close()
    end,
  })

  -- Last line of defence for §7.4: if anything tears the float window down
  -- without going through close(), the temporary mappings would otherwise be
  -- stranded in the user's own buffer as ghost keys.
  vim.api.nvim_create_autocmd('WinClosed', {
    group = self.augroup,
    pattern = tostring(self.win),
    callback = function()
      self:close()
    end,
  })

  self.spinner_timer = uv.new_timer()
  self.spinner_timer:start(
    SPINNER_INTERVAL,
    SPINNER_INTERVAL,
    vim.schedule_wrap(function()
      if self.state ~= 'loading' or not self:is_open() then
        return
      end
      self.spinner_frame = self.spinner_frame % #SPINNER + 1
      self:_refresh_config(true)
    end)
  )

  return self
end

return M
