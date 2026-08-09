--- 翻译调度层 (Translator). Everything the Provider deliberately does not know
--- about: the cache, the grace period, the in-flight table, the concurrency
--- gate, retries and timeouts. The relationship is one-way — a provider never
--- learns this layer exists (spec §2).
local M = {}

local cache = require('translate.cache')
local prompt = require('translate.prompt')

--- Only a failure that might simply go away on its own is worth repeating.
--- `auth`, `quota` and `bad_request` all need a human, and retrying them just
--- burns the rate limit.
local RETRYABLE = { rate_limit = true, server = true, network = true }

local RETRY_BASE_MS = 1000
local RETRY_JITTER_MS = 500

local Translator = {}
Translator.__index = Translator

--- @param opts table provider, store, timer, system, prompt_fp, target_lang,
--- temperature, thinking, grace_period, max_concurrent, queue_size,
--- first_byte_timeout, stall_timeout, max_retries
function M.new(opts)
  return setmetatable({
    provider = opts.provider,
    store = opts.store,
    timer = opts.timer,
    system = opts.system,
    prompt_fp = opts.prompt_fp,
    target_lang = opts.target_lang,
    temperature = opts.temperature,
    thinking = opts.thinking,
    grace_period = opts.grace_period,
    max_bytes = opts.max_bytes,
    max_concurrent = opts.max_concurrent,
    queue_size = opts.queue_size,
    first_byte_timeout = opts.first_byte_timeout,
    stall_timeout = opts.stall_timeout,
    max_retries = opts.max_retries,

    --- 在途请求表 (In-flight Request table), indexed by cache key — which is
    --- what makes repeat triggers of one paragraph deduplicate for free.
    entries = {},
    queue = {},
    active = 0,
  }, Translator)
end

function Translator:key(src)
  return cache.key({
    text = src.text,
    block_type = src.block_type,
    target_lang = self.target_lang,
    provider = self.provider.name,
    model = self.provider.model,
    prompt_fp = self.prompt_fp,
  })
end

local function stop(entry, name)
  if entry[name] ~= nil then
    entry[name]:stop()
    entry[name] = nil
  end
end

local function stop_all(entry)
  stop(entry, 'grace_timer')
  stop(entry, 'first_byte_timer')
  stop(entry, 'stall_timer')
  stop(entry, 'retry_timer')
end

local function notify(entry, event, ...)
  -- Iterate a copy: a subscriber may release its ticket from inside a callback.
  for _, sub in ipairs(vim.list_slice(entry.subscribers, 1)) do
    local fn = sub[event]
    if fn ~= nil then
      fn(...)
    end
  end
end

function Translator:_meta(entry, extra)
  return vim.tbl_extend('force', {
    cached = false,
    fence_mismatch = false,
    provider = self.provider.name,
    model = self.provider.model,
  }, extra or {})
end

--- A key must never outlive its entry in the queue: the gate measures capacity
--- with `#self.queue`, so a stale key would refuse work on behalf of a request
--- that no longer exists (§6.7).
function Translator:_dequeue(key)
  for i, queued in ipairs(self.queue) do
    if queued == key then
      table.remove(self.queue, i)
      return
    end
  end
end

function Translator:_finish(entry)
  stop_all(entry)
  self:_dequeue(entry.key)
  self.entries[entry.key] = nil
  if entry.state == 'running' then
    self.active = self.active - 1
  end
  self:_pump()
end

--- Start whatever the freed slot can now accommodate.
function Translator:_pump()
  while self.active < self.max_concurrent and #self.queue > 0 do
    local key = table.remove(self.queue, 1)
    local entry = self.entries[key]
    -- An entry abandoned while queued was deleted outright, so this key may no
    -- longer exist: skip it and keep pumping.
    if entry ~= nil and entry.state == 'queued' then
      self:_start(entry)
    end
  end
end

--- Timeout callbacks are checked against this counter. A real timer fires on the
--- libuv thread and *schedules* its callback; a chunk arriving in that gap stops
--- the timer but cannot un-queue what already fired. Without the check, a
--- healthy stream gets aborted by a timeout it had already beaten.
local function supersede_timeouts(entry)
  entry.timeout_generation = (entry.timeout_generation or 0) + 1
  return entry.timeout_generation
end

function Translator:_arm_stall(entry)
  stop(entry, 'stall_timer')
  local generation = supersede_timeouts(entry)
  entry.stall_timer = self.timer.start(self.stall_timeout, function()
    if entry.timeout_generation ~= generation then
      return
    end
    self:_fail(entry, {
      class = 'network',
      message = ('响应停滞超过 %d 秒'):format(math.floor(self.stall_timeout / 1000)),
    })
  end)
end

function Translator:_fail(entry, err)
  if self.entries[entry.key] ~= entry then
    return
  end
  stop_all(entry)
  if entry.handle ~= nil then
    entry.handle.abort()
    entry.handle = nil
  end
  self:_on_error(entry, err)
end

function Translator:_on_error(entry, err)
  stop_all(entry)

  -- Only a request that has produced nothing yet may be repeated. Once text is
  -- on screen, resetting it is more confusing than saying "it broke", and the
  -- tokens behind it are already spent (§6.8).
  local retryable = entry.acc == '' and RETRYABLE[err.class] and entry.attempts <= self.max_retries
  if retryable then
    local delay = RETRY_BASE_MS * 2 ^ (entry.attempts - 1) + math.random(0, RETRY_JITTER_MS - 1)
    entry.handle = nil

    -- The gate caps requests that are *in flight*, and nothing is in flight
    -- during a backoff. Holding the slot would let one burst of 429s collapse
    -- throughput to zero for the whole backoff window (§6.7).
    if entry.state == 'running' then
      entry.state = 'backoff'
      self.active = self.active - 1
    end

    entry.retry_timer = self.timer.start(math.floor(delay), function()
      if self.entries[entry.key] ~= entry then
        return
      end
      entry.retry_timer = nil
      if self.active < self.max_concurrent then
        self:_start(entry)
      else
        -- Back to the front: it has already waited once.
        entry.state = 'queued'
        table.insert(self.queue, 1, entry.key)
      end
    end)

    self:_pump()
    return
  end

  notify(entry, 'on_error', err)
  self:_finish(entry)
end

--- Issue the request. `entry.state` is already 'running'; retries come back
--- here without passing through the queue again.
function Translator:_send(entry)
  entry.attempts = entry.attempts + 1

  local generation = supersede_timeouts(entry)
  entry.first_byte_timer = self.timer.start(self.first_byte_timeout, function()
    if entry.timeout_generation ~= generation then
      return
    end
    self:_fail(entry, {
      class = 'network',
      message = ('%d 秒内没有收到任何响应'):format(math.floor(self.first_byte_timeout / 1000)),
    })
  end)

  local req = {
    -- Already-rendered user message: the adapter does no prompt work.
    text = prompt.user_message(entry.source.text),
    system = self.system,
    model = self.provider.model,
    temperature = self.temperature,
    thinking = self.thinking,
  }

  entry.handle = self.provider.translate(req, {
    on_chunk = function(delta)
      if self.entries[entry.key] ~= entry then
        return
      end
      stop(entry, 'first_byte_timer')
      self:_arm_stall(entry)
      entry.acc = entry.acc .. delta
      notify(entry, 'on_chunk', delta)
    end,

    on_done = function()
      if self.entries[entry.key] ~= entry then
        return
      end
      stop_all(entry)

      local mismatch = not prompt.fences_match(entry.source.text, entry.acc)

      -- Written even with nobody listening: that is what the grace period is
      -- for — reclaiming tokens already paid for (§6.6).
      self:_store(entry, mismatch)

      notify(entry, 'on_done', entry.acc, self:_meta(entry, { fence_mismatch = mismatch }))
      self:_finish(entry)
    end,

    on_error = function(err)
      if self.entries[entry.key] ~= entry then
        return
      end
      entry.handle = nil
      self:_on_error(entry, err)
    end,
  })
end

function Translator:_store(entry, mismatch)
  if entry.bypass_cache or entry.acc == '' then
    return
  end
  self.store:put(entry.key, {
    src = cache.key_source(entry.source.text, entry.source.block_type),
    dst = entry.acc,
    lang = self.target_lang,
    provider = self.provider.name,
    model = self.provider.model,
    prompt_fp = self.prompt_fp,
    fence_mismatch = mismatch or nil,
  })

  -- No-op unless the user opted into a ceiling: translations do not expire, so
  -- the default is to keep everything (§6.4).
  self.store:evict(self.max_bytes)
end

function Translator:_start(entry)
  entry.state = 'running'
  self.active = self.active + 1
  self:_send(entry)
end

function Translator:_release(entry, callbacks)
  for i, sub in ipairs(entry.subscribers) do
    if sub == callbacks then
      table.remove(entry.subscribers, i)
      break
    end
  end

  if #entry.subscribers > 0 or self.entries[entry.key] ~= entry then
    return
  end

  if entry.state == 'queued' or entry.state == 'backoff' then
    -- Nothing has been spent on a request that is queued or between attempts,
    -- so abandoning it means it is simply never sent — and its queue slot goes
    -- back immediately (§6.7).
    stop_all(entry)
    self:_dequeue(entry.key)
    self.entries[entry.key] = nil
    return
  end

  -- Do not cancel yet: a translation that lands inside the grace period is
  -- still worth keeping (§6.6).
  stop(entry, 'grace_timer')
  entry.grace_timer = self.timer.start(self.grace_period, function()
    if self.entries[entry.key] ~= entry or #entry.subscribers > 0 then
      return
    end
    if entry.handle ~= nil then
      entry.handle.abort()
      entry.handle = nil
    end
    self:_finish(entry)
  end)
end

--- @param src table { text, block_type, range }
--- @param callbacks table on_cached / on_replay / on_chunk / on_done / on_error
--- @param opts table|nil { bypass_cache = boolean }
--- @return table ticket with `release()`
function Translator:request(src, callbacks, opts)
  opts = opts or {}
  local key = self:key(src)

  local inert = { release = function() end }

  if not opts.bypass_cache then
    local hit = self.store:get(key)
    if hit ~= nil then
      -- Rendered whole, with no streaming animation: when the network is fast
      -- the two are hard to tell apart, and "this one was free" is worth
      -- knowing on a plugin that costs money (§6.5).
      if callbacks.on_cached ~= nil then
        callbacks.on_cached(
          hit.dst,
          self:_meta(nil, {
            cached = true,
            fence_mismatch = not prompt.fences_match(src.text, hit.dst),
          })
        )
      end
      return inert
    end
  end

  local entry = self.entries[key]

  if entry ~= nil then
    stop(entry, 'grace_timer')
    table.insert(entry.subscribers, callbacks)
    -- Fill in what already arrived, then carry on streaming (§6.6).
    if entry.acc ~= '' and callbacks.on_replay ~= nil then
      callbacks.on_replay(entry.acc)
    end
  else
    entry = {
      key = key,
      source = src,
      subscribers = { callbacks },
      acc = '',
      attempts = 0,
      state = 'queued',
      bypass_cache = opts.bypass_cache,
    }

    if self.active >= self.max_concurrent and #self.queue >= self.queue_size then
      if callbacks.on_error ~= nil then
        callbacks.on_error({
          class = 'rate_limit',
          message = ('本地请求队列已满（%d 并发 / %d 排队）'):format(self.max_concurrent, self.queue_size),
        })
      end
      return inert
    end

    self.entries[key] = entry
    if self.active < self.max_concurrent then
      self:_start(entry)
    else
      table.insert(self.queue, key)
    end
  end

  local released = false
  return {
    release = function()
      if released then
        return
      end
      released = true
      self:_release(entry, callbacks)
    end,
  }
end

--- Abort everything and forget it. Used on VimLeavePre.
function Translator:shutdown()
  for key, entry in pairs(self.entries) do
    stop_all(entry)
    if entry.handle ~= nil then
      entry.handle.abort()
    end
    self.entries[key] = nil
  end
  self.queue = {}
  self.active = 0
end

return M
