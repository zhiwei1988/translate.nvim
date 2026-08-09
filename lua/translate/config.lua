--- setup() schema and the effective configuration (CONTEXT.md: 生效配置).
--- Fixed for the whole nvim session — there is no runtime switching (spec §9.1),
--- which is what lets every component of the cache key be a session constant.
local M = {}

--- Options whose value is a list, not a namespace: merging them element-wise
--- would make it impossible to *shrink* a default list.
local LIST_OPTIONS = { markdown_filetypes = true }

local function defaults()
  return {
    -- Engine
    provider = 'deepseek',
    model = nil,
    api_key = nil,
    presets = {},

    -- Translation
    target_lang = 'Chinese',
    extra_instructions = nil,
    system_prompt = nil,
    temperature = 0.3,
    thinking = false,

    -- Paragraph detection
    markdown_filetypes = { 'markdown' },

    -- Translation float
    float = {
      max_height = 0.5,
      keymaps = {
        scroll_down = '<C-d>',
        scroll_up = '<C-u>',
        close = '<Esc>',
      },
    },

    -- Persistent cache
    cache = {
      dir = vim.fn.stdpath('cache') .. '/translate',
      max_bytes = nil,
      grace_period = 3000,
    },

    -- Transport and scheduling
    request = {
      max_concurrent = 4,
      queue_size = 16,
      first_byte_timeout = 30000,
      stall_timeout = 20000,
      max_retries = 2,
      -- Not part of the user-facing schema in spec §10. It exists because §8
      -- calls for an injectable fake `curl` executable to drive the SSE tests.
      curl = 'curl',
    },
  }
end

local function merge(base, override)
  if override == nil then
    return base
  end
  for k, v in pairs(override) do
    if type(v) == 'table' and type(base[k]) == 'table' and not LIST_OPTIONS[k] and not vim.islist(v) then
      merge(base[k], v)
    else
      base[k] = v
    end
  end
  return base
end

local state = { options = defaults(), configured = false }

function M.setup(opts)
  state.options = merge(defaults(), opts)
  state.configured = true
  return state.options
end

function M.get()
  return state.options
end

function M.is_configured()
  return state.configured
end

--- Test-only: drop back to pristine defaults.
function M.reset()
  state.options = defaults()
  state.configured = false
end

return M
