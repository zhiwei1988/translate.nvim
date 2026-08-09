local eq = MiniTest.expect.equality
local neq = MiniTest.expect.no_equality
local cache = require('translate.cache')

local uv = vim.uv or vim.loop
local dir, store

local function entry(over)
  return vim.tbl_extend('force', {
    src = 'Hello world.',
    dst = '你好，世界。',
    lang = 'Chinese',
    provider = 'deepseek',
    model = 'deepseek-v4-flash',
    prompt_fp = 'abc123',
  }, over or {})
end

local function read_file(path)
  local fd = assert(uv.fs_open(path, 'r', 438))
  local stat = assert(uv.fs_fstat(fd))
  local data = assert(uv.fs_read(fd, stat.size, 0))
  uv.fs_close(fd)
  return data
end

describe('cache store', function()
  before_each(function()
    dir = vim.fn.tempname()
    store = cache.new(dir)
  end)

  after_each(function()
    vim.fn.delete(dir, 'rf')
  end)

  it('returns nil for a key it has never seen', function()
    eq(store:get('deadbeefcafe'), nil)
  end)

  it('round-trips an entry', function()
    store:put('deadbeefcafe', entry())
    local got = store:get('deadbeefcafe')
    eq(got.dst, '你好，世界。')
    eq(got.model, 'deepseek-v4-flash')
    eq(got.lang, 'Chinese')
  end)

  it('stamps the entry as self-describing: version and creation time', function()
    store:put('deadbeefcafe', entry())
    local got = store:get('deadbeefcafe')
    eq(got.v, 1)
    eq(type(got.created_at), 'number')
  end)

  -- §6.2: shard by the first two hex chars so one directory never holds
  -- ten thousand files.
  it('shards on disk by the first two key characters', function()
    store:put('deadbeefcafe', entry())
    eq(uv.fs_stat(dir .. '/de/adbeefcafe.json') ~= nil, true)
  end)

  it('survives a corrupt entry file instead of throwing', function()
    store:put('deadbeefcafe', entry())
    local fd = assert(uv.fs_open(dir .. '/de/adbeefcafe.json', 'w', 384))
    uv.fs_write(fd, '{not json', 0)
    uv.fs_close(fd)
    eq(store:get('deadbeefcafe'), nil)
  end)

  it('ignores entries written by a future format version', function()
    store:put('deadbeefcafe', entry())
    local path = dir .. '/de/adbeefcafe.json'
    local decoded = vim.json.decode(read_file(path))
    decoded.v = 99
    local fd = assert(uv.fs_open(path, 'w', 384))
    uv.fs_write(fd, vim.json.encode(decoded), 0)
    uv.fs_close(fd)
    eq(store:get('deadbeefcafe'), nil)
  end)

  -- §6.2: $HOME is commonly mounted `relatime`, so atime-based LRU is a lie.
  -- mtime has to be maintained from day one or the eviction order is silently
  -- wrong the day someone turns `max_bytes` on.
  it('touches mtime on a hit without rewriting the file', function()
    store:put('deadbeefcafe', entry())
    local path = dir .. '/de/adbeefcafe.json'
    local before_bytes = read_file(path)
    local before = assert(uv.fs_stat(path))

    local old = before.mtime.sec - 10000
    assert(uv.fs_utime(path, old, old))
    eq(uv.fs_stat(path).mtime.sec, old)

    eq(store:get('deadbeefcafe').dst, '你好，世界。')

    local after = assert(uv.fs_stat(path))
    eq(after.mtime.sec > old, true)
    eq(after.ino, before.ino) -- not replaced via rename
    eq(read_file(path), before_bytes) -- not rewritten in place
  end)
end)

describe('cache stats and clearing', function()
  before_each(function()
    dir = vim.fn.tempname()
    store = cache.new(dir)
    store:put('aa11', entry())
    store:put('bb22', entry({ model = 'gemini-2.5-flash', provider = 'gemini' }))
    store:put('cc33', entry({ lang = 'Japanese' }))
  end)

  after_each(function()
    vim.fn.delete(dir, 'rf')
  end)

  it('counts entries and total bytes', function()
    local s = store:stats()
    eq(s.count, 3)
    eq(s.bytes > 0, true)
  end)

  it('groups by model and by target language', function()
    local s = store:stats()
    eq(s.by_model['deepseek-v4-flash'], 2)
    eq(s.by_model['gemini-2.5-flash'], 1)
    eq(s.by_lang['Chinese'], 2)
    eq(s.by_lang['Japanese'], 1)
  end)

  it('clears everything when given no model', function()
    eq(store:clear(), 3)
    eq(store:stats().count, 0)
  end)

  it('clears only the requested model', function()
    eq(store:clear('gemini-2.5-flash'), 1)
    local s = store:stats()
    eq(s.count, 2)
    eq(s.by_model['gemini-2.5-flash'], nil)
  end)

  it('reports a stat-able but absent directory as empty', function()
    local empty = cache.new(vim.fn.tempname())
    eq(empty:stats().count, 0)
  end)
end)

describe('cache eviction (§6.4)', function()
  before_each(function()
    dir = vim.fn.tempname()
    store = cache.new(dir)
  end)

  after_each(function()
    vim.fn.delete(dir, 'rf')
  end)

  it('does nothing when max_bytes is nil — translations do not expire', function()
    store:put('aa11', entry())
    eq(store:evict(nil), 0)
    eq(store:stats().count, 1)
  end)

  it('drops the least recently used entries first', function()
    for i, k in ipairs({ 'aa11', 'bb22', 'cc33' }) do
      store:put(k, entry({ dst = string.rep('x', 200) }))
      local path = dir .. '/' .. k:sub(1, 2) .. '/' .. k:sub(3) .. '.json'
      local t = 1700000000 + i * 100
      assert(uv.fs_utime(path, t, t))
    end

    local total = store:stats().bytes
    local removed = store:evict(math.floor(total * 2 / 3))

    eq(removed, 1)
    eq(store:get('aa11'), nil) -- oldest mtime
    neq(store:get('cc33'), nil) -- newest mtime
  end)
end)

describe('cache concurrent writers (§6.2)', function()
  before_each(function()
    dir = vim.fn.tempname()
    store = cache.new(dir)
  end)

  after_each(function()
    vim.fn.delete(dir, 'rf')
  end)

  -- Two nvim instances racing on one key must never leave a torn file. The
  -- layout is what makes this safe: same-filesystem rename is atomic, and both
  -- writers produce byte-identical content anyway.
  it('leaves a readable entry when several processes write the same key at once', function()
    local root = vim.g.translate_test_root
    local script = dir .. '_writer.lua'
    vim.fn.writefile({
      ([[vim.opt.runtimepath:prepend(%q)]]):format(root),
      ([[local store = require('translate.cache').new(%q)]]):format(dir),
      [[for _ = 1, 30 do]],
      [[  store:put('deadbeefcafe', { src = 'Hello world.', dst = string.rep('你好', 400),]],
      [[    lang = 'Chinese', provider = 'deepseek', model = 'm', prompt_fp = 'fp' })]],
      [[end]],
    }, script)

    local procs = {}
    for _ = 1, 4 do
      procs[#procs + 1] = vim.system({ vim.v.progpath, '--headless', '-l', script })
    end
    for _, p in ipairs(procs) do
      eq(p:wait(60000).code, 0)
    end

    local got = store:get('deadbeefcafe')
    neq(got, nil)
    eq(got.dst, string.rep('你好', 400))

    -- No temporary files orphaned in the shard.
    eq(vim.fn.glob(dir .. '/de/*.tmp*', false, true), {})
    vim.fn.delete(script)
  end)
end)
