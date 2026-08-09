--- API key resolution: explicit configuration beats implicit environment.
local M = {}

--- Callable keys usually shell out to `pass` or `op`. Forking a process per
--- request would make every translation pay that cost, so the value is cached
--- for the process — with a way to clear it so keys can be rotated (§5.6).
local cache = setmetatable({}, { __mode = 'k' })

function M.clear_cache()
  cache = setmetatable({}, { __mode = 'k' })
end

local function auth_error(message, preset)
  return nil,
    {
      class = 'auth',
      message = message,
      hint = ('请设置环境变量 %s，或在 setup() 中显式传入 api_key。'):format(
        preset.api_key_env or '(该 preset 未声明环境变量)'
      ),
    }
end

--- @return string|nil key, table|nil err
function M.resolve(cfg, preset)
  local configured = cfg.api_key

  if type(configured) == 'function' then
    if cache[configured] == nil then
      local ok, value = pcall(configured)
      if not ok then
        return auth_error(('求值 api_key 函数失败：%s'):format(tostring(value)), preset)
      end
      if type(value) ~= 'string' or value == '' then
        return auth_error('api_key 函数没有返回非空字符串', preset)
      end
      cache[configured] = value
    end
    return cache[configured]
  end

  if type(configured) == 'string' and configured ~= '' then
    return configured
  end

  local env_name = preset.api_key_env
  if env_name == nil then
    -- The preset declares no environment variable, i.e. the service needs no
    -- credential (a local Ollama, say). Not an error, and no header to send.
    return ''
  end

  local from_env = vim.env[env_name]
  if type(from_env) == 'string' and from_env ~= '' then
    return from_env
  end

  return auth_error(('未找到 %s 的 API key'):format(preset.name or 'provider'), preset)
end

--- Whether the preset's environment variable currently holds something.
--- Deliberately boolean: `:checkhealth` must never print any part of a key.
function M.env_present(preset)
  local name = preset.api_key_env
  if name == nil then
    return false
  end
  local value = vim.env[name]
  return type(value) == 'string' and value ~= ''
end

return M
