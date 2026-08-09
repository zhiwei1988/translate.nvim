--- Public surface: setup() plus the two functions the `<Plug>` mappings call.
---
--- Nothing here can be switched at runtime. Provider, model, target language and
--- prompt are fixed for the session (CONTEXT.md: 生效配置), which is exactly what
--- makes every component of the cache key a constant.
local M = {}

local cache = require('translate.cache')
local config = require('translate.config')
local detect = require('translate.detect')
local errors = require('translate.errors')
local float = require('translate.float')
local prompt = require('translate.prompt')
local provider = require('translate.provider')
local timer = require('translate.timer')
local translator = require('translate.translator')

local state = { translator = nil, float = nil }

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'translate.nvim' })
end

--- Built once per session and memoised: the effective configuration cannot
--- change under it.
--- @return table|nil translator, table|nil err
function M._engine()
  if state.translator ~= nil then
    return state.translator
  end

  local cfg = config.get()
  local engine, err = provider.resolve(cfg)
  if engine == nil then
    return nil, err
  end

  local system = prompt.render(cfg)
  state.translator = translator.new({
    provider = engine,
    store = cache.new(cfg.cache.dir),
    timer = timer,
    system = system,
    prompt_fp = prompt.fingerprint(system),
    target_lang = cfg.target_lang,
    temperature = cfg.temperature,
    thinking = cfg.thinking,
    grace_period = cfg.cache.grace_period,
    max_bytes = cfg.cache.max_bytes,
    max_concurrent = cfg.request.max_concurrent,
    queue_size = cfg.request.queue_size,
    first_byte_timeout = cfg.request.first_byte_timeout,
    stall_timeout = cfg.request.stall_timeout,
    max_retries = cfg.request.max_retries,
  })
  return state.translator
end

--- Open the float and drive it from one request. Only ever one float at a time.
local function start(win, buf, source)
  local engine, err = M._engine()
  if engine == nil then
    return notify(errors.format(err), vim.log.levels.ERROR)
  end

  if state.float ~= nil then
    state.float:close()
  end

  local cfg = config.get()
  local ticket

  local window = float.open({
    win = win,
    buf = buf,
    range = source.range,
    provider = engine.provider.name,
    model = engine.provider.model,
    max_height = cfg.float.max_height,
    keymaps = cfg.float.keymaps,
    on_close = function()
      state.float = nil
      -- Closing the window starts the grace period rather than cancelling:
      -- the tokens are already being paid for (§6.6).
      if ticket ~= nil then
        ticket:release()
      end
    end,
  })
  state.float = window

  ticket = engine:request(source, {
    on_cached = function(text, meta)
      window:set_text(text)
      window:mark_cached()
      if meta.fence_mismatch then
        window:mark_fence_mismatch()
      end
    end,
    on_replay = function(text)
      window:set_text(text)
    end,
    on_chunk = function(delta)
      window:append(delta)
    end,
    on_done = function(_, meta)
      window:finish()
      if meta.fence_mismatch then
        window:mark_fence_mismatch()
      end
    end,
    on_error = function(request_err)
      window:fail(request_err)
    end,
  })
end

function M.setup(opts)
  config.setup(opts)
  state.translator = nil
  require('translate.commands').setup()
  return M
end

--- Translate the 段落 under the cursor.
function M.translate()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(win)[1] - 1

  local source, reason = detect.paragraph(buf, row, config.get().markdown_filetypes)
  if source == nil then
    -- Deliberately no hunt for a nearby paragraph: quietly translating the
    -- neighbour is more confusing than doing nothing (§3.1).
    return notify(detect.REASONS[reason] or '未找到可翻译的段落', vim.log.levels.WARN)
  end

  start(win, buf, source)
end

--- Translate the visual selection. Must be reached through a `<Cmd>` mapping so
--- that visual mode is still active and the columns are this selection's.
function M.translate_selection()
  local source = detect.selection()
  if source == nil then
    return notify('选区为空，未发起翻译', vim.log.levels.WARN)
  end

  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()

  -- Leave visual mode before the float's CursorMoved autocmd exists, so exiting
  -- does not immediately close it.
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)

  start(win, buf, source)
end

--- Explicit-range entry point, for callers that already know the selection.
function M.translate_selection_range(start_pos, end_pos, mode)
  local buf = vim.api.nvim_get_current_buf()
  local source = detect.selection_from(buf, start_pos, end_pos, mode)
  if source == nil then
    return notify('选区为空，未发起翻译', vim.log.levels.WARN)
  end
  start(vim.api.nvim_get_current_win(), buf, source)
end

function M._float()
  if state.float ~= nil and state.float:is_open() then
    return state.float
  end
  return nil
end

--- Test seam: drop the memoised engine and any open window.
function M._reset()
  if state.float ~= nil then
    state.float:close()
  end
  if state.translator ~= nil then
    state.translator:shutdown()
  end
  state = { translator = nil, float = nil }
end

return M
