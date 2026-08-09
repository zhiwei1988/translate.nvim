--- 厂商预设 (Preset): everything that differs between services sitting on the
--- same OpenAI-compatible protocol — endpoint, auth, default model, parameter
--- quirks. Covers ~90% of providers; only a genuinely incompatible API needs a
--- full adapter (spec §5.7).
local M = {}

M.builtin = {
  deepseek = {
    name = 'deepseek',
    base_url = 'https://api.deepseek.com',
    -- Note the absence of /v1/: DeepSeek's OpenAI-compatible endpoint is
    -- mounted at the root.
    path = '/chat/completions',
    api_key_env = 'DEEPSEEK_API_KEY',
    model = 'deepseek-v4-flash',
    thinking = {
      off = { thinking = { type = 'disabled' } },
      on = { thinking = { type = 'enabled' } },
    },
    -- Deprecated upstream; passing them through returns 422.
    drop_params = { 'frequency_penalty', 'presence_penalty' },
    billing_url = 'https://platform.deepseek.com',
  },

  gemini = {
    name = 'gemini',
    base_url = 'https://generativelanguage.googleapis.com/v1beta/openai/',
    path = '/chat/completions',
    api_key_env = 'GEMINI_API_KEY',
    -- 2.5 is the last generation whose thinking can be switched off entirely;
    -- for translation, predictable latency and cost beat model recency.
    model = 'gemini-2.5-flash',
    thinking = {
      off = { reasoning_effort = 'none' },
      on = {},
    },
    billing_url = 'https://aistudio.google.com',
  },
}

--- @return table|nil preset, nil when the name is unknown
function M.resolve(name, user_presets)
  local custom = (user_presets or {})[name]
  if custom ~= nil then
    return vim.tbl_extend('keep', { name = name }, custom)
  end
  return M.builtin[name]
end

function M.names(user_presets)
  local names = vim.tbl_keys(M.builtin)
  for name in pairs(user_presets or {}) do
    if not vim.tbl_contains(names, name) then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

return M
