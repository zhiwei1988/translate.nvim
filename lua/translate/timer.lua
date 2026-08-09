--- The scheduler's only clock, behind a two-function interface so tests can
--- drive the grace period, backoff and timeouts without waiting on wall time.
local M = {}

local uv = vim.uv or vim.loop

--- @return table handle with `stop()`
function M.start(ms, fn)
  local timer = uv.new_timer()
  local stopped = false

  local function close()
    if not stopped then
      stopped = true
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
    end
  end

  timer:start(ms, 0, function()
    close()
    vim.schedule(fn)
  end)

  return { stop = close }
end

return M
