--- Turns the effective configuration into a bound Provider (CONTEXT.md: Provider).
---
--- Two extension points, in order of how often they are the right one:
---   * a Preset — endpoint, auth, default model, parameter quirks;
---   * a full adapter — a table carrying its own `translate`, for an API that
---     is not OpenAI-compatible at all.
local M = {}

local keys = require('translate.provider.keys')
local openai = require('translate.provider.openai')
local presets = require('translate.provider.presets')

--- @return table|nil provider { name, model, translate }, table|nil err
function M.resolve(cfg)
  local preset = presets.resolve(cfg.provider, cfg.presets)
  if preset == nil then
    return nil,
      {
        class = 'bad_request',
        message = ('未知的 provider "%s"'):format(tostring(cfg.provider)),
        hint = ('可用：%s。自定义请通过 setup({ presets = { ... } }) 注册。'):format(
          table.concat(presets.names(cfg.presets), ', ')
        ),
      }
  end

  local model = cfg.model or preset.model

  -- A full adapter owns its own transport, and therefore its own credentials.
  if type(preset.translate) == 'function' then
    return { name = preset.name, model = model, preset = preset, translate = preset.translate }
  end

  local api_key, err = keys.resolve(cfg, preset)
  if api_key == nil then
    return nil, err
  end

  local bound = openai.new({
    preset = preset,
    api_key = api_key,
    curl = (cfg.request or {}).curl or 'curl',
  })

  return { name = preset.name, model = model, preset = preset, translate = bound.translate }
end

return M
