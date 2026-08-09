--- Human-facing rendering of the error shape from spec §5.5
--- (`{ class, message, status, hint }`).
---
--- One place, so the float, the notification and `:TranslatePing` cannot drift
--- apart on how a failure reads — `auth` and `quota` in particular carry a hint
--- that must survive, because those are the two the user has to act on.
local M = {}

--- @param err table { class, message, hint }
--- @param prefix string|nil defaults to the translation-failed wording
function M.format(err, prefix)
  local text = ('%s：%s'):format(prefix or '翻译失败', err.message or err.class or '未知错误')
  if err.hint ~= nil and err.hint ~= '' then
    text = text .. '\n' .. err.hint
  end
  return text
end

return M
