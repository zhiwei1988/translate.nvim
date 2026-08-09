local H = {}

--- A manually advanced clock. The scheduler's grace period, retry backoff and
--- timeouts are measured in tens of seconds; driving them off real timers would
--- make the suite unusable, and sleeping is not a test.
function H.fake_clock()
  local c = { now = 0, seq = 0, timers = {}, requested = {} }

  function c.start(ms, fn)
    c.seq = c.seq + 1
    local t = { at = c.now + ms, fn = fn, seq = c.seq, alive = true }
    table.insert(c.timers, t)
    table.insert(c.requested, ms)
    return {
      stop = function()
        t.alive = false
      end,
    }
  end

  --- Fire every timer due within `ms`, in due order, letting callbacks arm
  --- further timers as they go.
  function c.advance(ms)
    local target = c.now + ms
    while true do
      local next_timer
      for _, t in ipairs(c.timers) do
        if t.alive and t.at <= target then
          if
            next_timer == nil
            or t.at < next_timer.at
            or (t.at == next_timer.at and t.seq < next_timer.seq)
          then
            next_timer = t
          end
        end
      end
      if next_timer == nil then
        break
      end
      c.now = next_timer.at
      next_timer.alive = false
      next_timer.fn()
    end
    c.now = target
  end

  --- The most recently armed timer, so a test can fire a callback that real
  --- timers would already have queued on the event loop before it was stopped.
  function c.last_armed()
    return c.timers[#c.timers]
  end

  function c.pending()
    return #vim.tbl_filter(function(t)
      return t.alive
    end, c.timers)
  end

  return c
end

--- A Provider whose stream the test drives by hand.
function H.fake_provider(over)
  local p = vim.tbl_extend('force', { name = 'fake', model = 'fake-model', calls = {} }, over or {})

  function p.translate(req, handlers)
    local call = { req = req, handlers = handlers, aborted = false }
    call.handle = {
      abort = function()
        call.aborted = true
      end,
    }
    table.insert(p.calls, call)
    return call.handle
  end

  function p.last()
    return p.calls[#p.calls]
  end

  return p
end

--- Records everything a subscriber was told.
function H.recorder()
  local r = { chunks = {}, replayed = nil, cached = nil, done = nil, meta = nil, err = nil }
  r.callbacks = {
    on_replay = function(text)
      r.replayed = text
    end,
    on_cached = function(text, meta)
      r.cached, r.meta = text, meta
    end,
    on_chunk = function(delta)
      table.insert(r.chunks, delta)
    end,
    on_done = function(text, meta)
      r.done, r.meta = text, meta
    end,
    on_error = function(err)
      r.err = err
    end,
  }
  return r
end

return H
