local eq = MiniTest.expect.equality
local neq = MiniTest.expect.no_equality

local H = dofile(vim.g.translate_test_root .. '/tests/helpers.lua')
local cache = require('translate.cache')
local translator = require('translate.translator')

local dir, clock, provider, T

local function build(over)
  clock = H.fake_clock()
  provider = H.fake_provider()
  dir = vim.fn.tempname()

  T = translator.new(vim.tbl_extend('force', {
    provider = provider,
    store = cache.new(dir),
    timer = clock,
    system = 'SYSTEM',
    prompt_fp = 'fp0',
    target_lang = 'Chinese',
    temperature = 0.3,
    thinking = false,
    grace_period = 3000,
    max_concurrent = 4,
    queue_size = 16,
    first_byte_timeout = 30000,
    stall_timeout = 20000,
    max_retries = 2,
  }, over or {}))

  return T
end

local function source(text, block_type)
  return { text = text or 'Hello world.', block_type = block_type or 'paragraph', range = { 0, 0 } }
end

local function request(src, over)
  local r = H.recorder()
  r.ticket = T:request(src or source(), r.callbacks)
  return r
end

local function teardown()
  vim.fn.delete(dir, 'rf')
end

describe('translator — cache interaction (§6.5)', function()
  before_each(build)
  after_each(teardown)

  it('renders a cache hit whole, with no request and no streaming', function()
    T.store:put(T:key(source()), { src = 'Hello world.', dst = '你好，世界。', lang = 'Chinese', model = 'fake-model' })

    local r = request()
    eq(r.cached, '你好，世界。')
    eq(r.meta.cached, true)
    eq(r.chunks, {})
    eq(#provider.calls, 0)
  end)

  it('writes a completed translation to the cache', function()
    local r = request()
    provider.last().handlers.on_chunk('你好')
    provider.last().handlers.on_done()

    eq(r.done, '你好')
    eq(T.store:get(T:key(source())).dst, '你好')
  end)

  -- A half-written translation cannot be resumed, so it must never become an
  -- entry (§6.5).
  it('does not write a stream that ended in an error', function()
    request()
    provider.last().handlers.on_chunk('你')
    provider.last().handlers.on_error({ class = 'server', message = 'boom' })

    eq(T.store:get(T:key(source())), nil)
  end)

  it('does not write an aborted stream', function()
    local r = request()
    provider.last().handlers.on_chunk('你')
    r.ticket:release()
    clock.advance(3000)

    eq(provider.last().aborted, true)
    eq(T.store:get(T:key(source())), nil)
  end)

  it('records the self-describing metadata alongside the translation', function()
    request()
    provider.last().handlers.on_chunk('你好')
    provider.last().handlers.on_done()

    local entry = T.store:get(T:key(source()))
    eq(entry.lang, 'Chinese')
    eq(entry.provider, 'fake')
    eq(entry.model, 'fake-model')
    eq(entry.prompt_fp, 'fp0')
    eq(entry.src, 'Hello world.')
  end)

  it('stops hitting old entries once the prompt fingerprint changes', function()
    request()
    provider.last().handlers.on_chunk('你好')
    provider.last().handlers.on_done()

    local same = T:key(source())
    build({ prompt_fp = 'fp1', store = cache.new(dir) })
    neq(T:key(source()), same)
    eq(request().cached, nil)
  end)

  it('still hits after only the temperature changed', function()
    request()
    provider.last().handlers.on_chunk('你好')
    provider.last().handlers.on_done()

    build({ temperature = 0.9, store = cache.new(dir) })
    eq(request().cached, '你好')
  end)
end)

describe('translator — eviction (§6.4)', function()
  after_each(teardown)

  it('leaves the cache unbounded by default', function()
    build()
    for i = 1, 5 do
      request(source('paragraph ' .. i))
      provider.calls[i].handlers.on_chunk(string.rep('译', 200))
      provider.calls[i].handlers.on_done()
    end
    eq(T.store:stats().count, 5)
  end)

  it('trims the least recently used entries once max_bytes is set', function()
    build({ max_bytes = 1500 })
    for i = 1, 5 do
      request(source('paragraph ' .. i))
      provider.calls[i].handlers.on_chunk(string.rep('译', 200))
      provider.calls[i].handlers.on_done()
    end
    local stats = T.store:stats()
    eq(stats.count < 5, true)
    eq(stats.bytes <= 1500, true)
  end)
end)

describe('translator — request shape', function()
  before_each(build)
  after_each(teardown)

  it('hands the provider a rendered system prompt and no target_lang', function()
    request()
    local req = provider.last().req
    eq(req.system, 'SYSTEM')
    eq(req.target_lang, nil)
    eq(req.model, 'fake-model')
    eq(req.temperature, 0.3)
    eq(req.thinking, false)
  end)

  it('wraps the paragraph in <source_text> byte-for-byte', function()
    request(source('  spaced\n\ttabbed  '))
    eq(provider.last().req.text, '<source_text>\n  spaced\n\ttabbed  \n</source_text>')
  end)
end)

describe('translator — in-flight reuse and the grace period (§6.6)', function()
  before_each(build)
  after_each(teardown)

  it('sends only one request when the same paragraph is triggered twice', function()
    request()
    request()
    eq(#provider.calls, 1)
  end)

  it('fans a delta out to every subscriber', function()
    local a = request()
    local b = request()
    provider.last().handlers.on_chunk('你好')
    eq(a.chunks, { '你好' })
    eq(b.chunks, { '你好' })
  end)

  -- Closing the window does not cancel: the tokens are already being paid for.
  it('does not abort when the window closes, for the length of the grace period', function()
    local r = request()
    r.ticket:release()
    clock.advance(2999)
    eq(provider.last().aborted, false)
  end)

  it('aborts once the grace period expires', function()
    local r = request()
    r.ticket:release()
    clock.advance(3000)
    eq(provider.last().aborted, true)
  end)

  it('silently caches a translation that lands inside the grace period', function()
    local r = request()
    r.ticket:release()
    clock.advance(1000)
    provider.last().handlers.on_chunk('你好')
    provider.last().handlers.on_done()

    eq(r.done, nil) -- nobody is listening any more
    eq(T.store:get(T:key(source())).dst, '你好')
    clock.advance(5000)
    eq(provider.last().aborted, false)
  end)

  -- Coming back to the paragraph must not restart the request, and must not
  -- lose the text that already arrived.
  it('reuses the in-flight request on return, replaying what has accumulated', function()
    local first = request()
    provider.last().handlers.on_chunk('你好')
    first.ticket:release()
    clock.advance(1000)
    provider.last().handlers.on_chunk('，世界')

    local second = request()
    eq(#provider.calls, 1)
    eq(second.replayed, '你好，世界')
    eq(second.chunks, {})

    provider.last().handlers.on_chunk('。')
    eq(second.chunks, { '。' })
  end)

  it('cancels the pending abort when a subscriber returns', function()
    local first = request()
    first.ticket:release()
    clock.advance(1000)
    request()
    clock.advance(10000)
    eq(provider.last().aborted, false)
  end)

  it('completes normally for the returning subscriber', function()
    local first = request()
    provider.last().handlers.on_chunk('你好')
    first.ticket:release()
    local second = request()
    provider.last().handlers.on_done()
    eq(second.done, '你好')
  end)

  it('is safe to release the same ticket twice', function()
    local r = request()
    r.ticket:release()
    r.ticket:release()
    clock.advance(3000)
    eq(provider.last().aborted, true)
  end)
end)

describe('translator — concurrency gate (§6.7)', function()
  before_each(build)
  after_each(teardown)

  local function distinct(n)
    local rs = {}
    for i = 1, n do
      rs[i] = request(source('paragraph number ' .. i))
    end
    return rs
  end

  it('lets four requests run and queues the fifth', function()
    distinct(5)
    eq(#provider.calls, 4)
  end)

  it('starts a queued request as soon as a slot frees up', function()
    local rs = distinct(5)
    eq(#provider.calls, 4)
    rs[1].ticket:release()
    provider.calls[1].handlers.on_done()
    eq(#provider.calls, 5)
  end)

  it('rejects with rate_limit once the queue is full', function()
    distinct(20)
    eq(#provider.calls, 4)
    local overflow = request(source('one paragraph too many'))
    eq(overflow.err.class, 'rate_limit')
  end)

  -- A queued request has not cost anything yet, so abandoning it means it is
  -- simply never sent (§6.7).
  it('never sends a queued request that was abandoned', function()
    local rs = distinct(5)
    rs[5].ticket:release()
    rs[1].ticket:release()
    provider.calls[1].handlers.on_done()

    eq(#provider.calls, 4)
    for _, call in ipairs(provider.calls) do
      eq(call.req.text:find('number 5', 1, true), nil)
    end
  end)

  -- §6.7 says an abandoned queued request is dropped from the queue. Only
  -- *not sending* it is not enough: if its key stays in the queue it keeps
  -- occupying capacity, and later requests are refused for a queue that is
  -- actually empty.
  it('gives the queue slot back when a queued request is abandoned', function()
    build({ max_concurrent = 1, queue_size = 2 })

    local a = request(source('paragraph A'))
    local b = request(source('paragraph B'))
    local c = request(source('paragraph C'))
    eq(#provider.calls, 1)

    b.ticket:release()
    c.ticket:release()

    local d = request(source('paragraph D'))
    local e = request(source('paragraph E'))
    eq(d.err, nil)
    eq(e.err, nil)

    -- And the freed capacity is real: finishing A starts D, not a ghost.
    a.ticket:release()
    provider.calls[1].handlers.on_done()
    eq(#provider.calls, 2)
    eq(provider.last().req.text:find('paragraph D', 1, true) ~= nil, true)
  end)

  it('does not let an abandoned queued request block the ones behind it', function()
    local rs = distinct(6)
    rs[5].ticket:release()
    rs[1].ticket:release()
    provider.calls[1].handlers.on_done()

    eq(#provider.calls, 5)
    eq(provider.last().req.text:find('number 6', 1, true) ~= nil, true)
  end)
end)

describe('translator — retry (§6.8)', function()
  before_each(build)
  after_each(teardown)

  local function fail(class)
    provider.last().handlers.on_error({ class = class, message = class })
  end

  it('retries a server error that arrived before any output', function()
    request()
    fail('server')
    eq(#provider.calls, 1)
    clock.advance(1500)
    eq(#provider.calls, 2)
  end)

  it('backs off exponentially with jitter', function()
    request()
    fail('server')
    local first = clock.requested[#clock.requested]
    eq(first >= 1000 and first < 1500, true)

    clock.advance(first)
    fail('server')
    local second = clock.requested[#clock.requested]
    eq(second >= 2000 and second < 2500, true)
  end)

  it('gives up after max_retries and reports the error', function()
    local r = request()
    fail('server')
    clock.advance(5000)
    fail('server')
    clock.advance(5000)
    eq(#provider.calls, 3)
    fail('server')
    clock.advance(5000)

    eq(#provider.calls, 3)
    eq(r.err.class, 'server')
  end)

  it('retries rate_limit and network too', function()
    request()
    fail('rate_limit')
    clock.advance(2000)
    eq(#provider.calls, 2)
    fail('network')
    clock.advance(3000)
    eq(#provider.calls, 3)
  end)

  it('never retries an error the user has to fix', function()
    local r = request()
    fail('auth')
    clock.advance(10000)
    eq(#provider.calls, 1)
    eq(r.err.class, 'auth')
  end)

  -- Retrying would reset half-rendered text in front of the reader, and the
  -- tokens behind it are already paid for (§6.8).
  it('never retries once a chunk has been rendered', function()
    local r = request()
    provider.last().handlers.on_chunk('你好')
    fail('server')
    clock.advance(10000)

    eq(#provider.calls, 1)
    eq(r.err.class, 'server')
    eq(r.chunks, { '你好' })
  end)

  -- §6.7 caps requests that are *in flight*. Nothing is in flight during a
  -- backoff, and holding the slot means a burst of 429s collapses throughput to
  -- zero for the whole backoff window.
  it('does not hold a concurrency slot while backing off', function()
    build({ max_concurrent = 1 })

    request(source('paragraph A'))
    eq(#provider.calls, 1)
    provider.last().handlers.on_error({ class = 'rate_limit', message = 'slow down' })

    request(source('paragraph B'))
    eq(#provider.calls, 2)
    eq(provider.last().req.text:find('paragraph B', 1, true) ~= nil, true)
  end)

  it('re-queues rather than exceeding the gate when the retry comes due', function()
    build({ max_concurrent = 1 })

    local a = request(source('paragraph A'))
    provider.last().handlers.on_error({ class = 'server', message = 'boom' })
    request(source('paragraph B'))
    eq(#provider.calls, 2)

    clock.advance(5000) -- A's retry falls due while B still holds the slot
    eq(#provider.calls, 2)

    provider.calls[2].handlers.on_done()
    eq(#provider.calls, 3)
    eq(provider.last().req.text:find('paragraph A', 1, true) ~= nil, true)
    eq(a.err, nil)
  end)

  it('drops a backing-off request that is abandoned, without sending it again', function()
    build({ max_concurrent = 1 })
    local a = request(source('paragraph A'))
    provider.last().handlers.on_error({ class = 'server', message = 'boom' })
    a.ticket:release()
    clock.advance(10000)
    eq(#provider.calls, 1)
  end)

  it('keeps the accumulated text through a retry', function()
    local r = request()
    fail('server')
    clock.advance(1500)
    provider.last().handlers.on_chunk('你好')
    provider.last().handlers.on_done()
    eq(r.done, '你好')
  end)
end)

describe('translator — timeouts (§6.9)', function()
  before_each(function()
    build({ max_retries = 0 })
  end)
  after_each(teardown)

  it('fails with network when no first byte arrives in 30s', function()
    local r = request()
    clock.advance(29999)
    eq(r.err, nil)
    clock.advance(1)
    eq(r.err.class, 'network')
    eq(provider.last().aborted, true)
  end)

  it('fails with network when the stream stalls for 20s between chunks', function()
    local r = request()
    clock.advance(10000)
    provider.last().handlers.on_chunk('你')
    clock.advance(19999)
    eq(r.err, nil)
    clock.advance(1)
    eq(r.err.class, 'network')
  end)

  it('resets the stall window on every chunk', function()
    local r = request()
    for _ = 1, 20 do
      provider.last().handlers.on_chunk('x')
      clock.advance(19000)
    end
    eq(r.err, nil)
  end)

  -- A long paragraph legitimately takes longer; a total-duration cap would only
  -- ever kill healthy translations (§6.9).
  it('does not impose a total duration limit', function()
    local r = request()
    provider.last().handlers.on_chunk('start')
    for _ = 1, 60 do -- five minutes of steady output
      clock.advance(5000)
      provider.last().handlers.on_chunk('x')
    end
    eq(r.err, nil)
    provider.last().handlers.on_done()
    eq(#r.chunks, 61)
  end)

  -- A real timer fires on the libuv thread and schedules its callback. A chunk
  -- arriving in that gap stops the timer, but cannot un-queue the callback that
  -- already fired — so the callback has to notice it has been superseded, or it
  -- kills a perfectly healthy stream.
  it('ignores a stall timeout that had already fired when a chunk landed', function()
    build()
    local r = request()
    provider.last().handlers.on_chunk('a')
    local stale = clock.last_armed()
    provider.last().handlers.on_chunk('b')

    stale.fn()

    eq(r.err, nil)
    eq(provider.last().aborted, false)
  end)

  it('ignores a first-byte timeout that raced the first chunk', function()
    build()
    local r = request()
    local stale = clock.last_armed()
    provider.last().handlers.on_chunk('a')

    stale.fn()

    eq(r.err, nil)
    eq(provider.last().aborted, false)
  end)

  it('stops the timers once the stream completes', function()
    request()
    provider.last().handlers.on_chunk('你好')
    provider.last().handlers.on_done()
    eq(clock.pending(), 0)
  end)
end)

describe('translator — fenced block integrity (§4.5)', function()
  before_each(build)
  after_each(teardown)

  local FENCED = 'Run this:\n\n```lua\nlocal x = 1\n```'

  it('reports a match when the code came back untouched', function()
    local r = request(source(FENCED, 'paragraph'))
    provider.last().handlers.on_chunk('执行：\n\n```lua\nlocal x = 1\n```')
    provider.last().handlers.on_done()
    eq(r.meta.fence_mismatch, false)
  end)

  -- Flagged only. Overwriting the block would mean rewriting text already drawn
  -- on screen, and the two sides need not even have the same number of blocks.
  it('flags a rewritten code block without touching the translation', function()
    local r = request(source(FENCED, 'paragraph'))
    local translated = '执行：\n\n```lua\n局部 x = 1\n```'
    provider.last().handlers.on_chunk(translated)
    provider.last().handlers.on_done()

    eq(r.meta.fence_mismatch, true)
    eq(r.done, translated)
  end)

  it('reports the flag on a cache hit too', function()
    local r = request(source(FENCED, 'paragraph'))
    provider.last().handlers.on_chunk('执行：\n\n```lua\n局部 x = 1\n```')
    provider.last().handlers.on_done()

    build({ store = cache.new(dir) })
    eq(request(source(FENCED, 'paragraph')).meta.fence_mismatch, true)
  end)
end)

describe('translator — bypass for :TranslatePing (§9.3)', function()
  before_each(build)
  after_each(teardown)

  -- A fixed probe that went through the cache would hit on the second run and
  -- report "all good" having tested nothing at all.
  it('neither reads nor writes the cache', function()
    T.store:put(T:key(source()), { src = 'Hello world.', dst = 'CACHED', lang = 'Chinese', model = 'fake-model' })

    local r = H.recorder()
    T:request(source(), r.callbacks, { bypass_cache = true })

    eq(r.cached, nil)
    eq(#provider.calls, 1)

    provider.last().handlers.on_chunk('FRESH')
    provider.last().handlers.on_done()
    eq(T.store:get(T:key(source())).dst, 'CACHED')
  end)
end)
