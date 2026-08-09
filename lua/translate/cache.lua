--- Persistent translation cache (CONTEXT.md: 缓存键 / 缓存条目).
---
--- Translations do not go stale, so there is no TTL: a change of model or prompt
--- is isolated by the key itself rather than by expiry (spec §6.4).
local M = {}

local uv = vim.uv or vim.loop

local FORMAT_VERSION = 1

local function trim(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

--- Whitespace-normalized source (CONTEXT.md: 规范化原文). Only ever used to
--- build a key — the provider always receives the original paragraph.
function M.normalize(text)
  local lines = {}
  for line in vim.gsplit(text, '\n', { plain = true }) do
    lines[#lines + 1] = trim(line)
  end
  return trim((table.concat(lines, ' '):gsub('%s+', ' ')))
end

--- Prose is the only place soft line-wrapping exists, so it is the only place
--- normalization buys anything. In a list or a table every line boundary is
--- authored structure: folding it would create collisions between genuinely
--- different content (spec §6.1).
function M.key_source(text, block_type)
  if block_type == 'paragraph' then
    return M.normalize(text)
  end
  return text
end

--- Length-prefixed so no field can impersonate a separator plus its neighbour.
local function join(...)
  local parts = {}
  for _, field in ipairs({ ... }) do
    local s = tostring(field)
    parts[#parts + 1] = ('%d:%s'):format(#s, s)
  end
  return table.concat(parts, '\0')
end

--- The joined material is binary — it carries NUL separators, and a field may
--- carry one of its own. A Lua string holding a NUL crosses into Vimscript as a
--- Blob rather than a String, and sha256() rejects a Blob with E976 on Neovim
--- 0.10, the oldest version this plugin supports. Hex encoding is injective, so
--- hashing the encoding hashes the same identity.
local function digest(material)
  return vim.fn.sha256(vim.text.hexencode(material))
end

--- Cache key for one paragraph under the effective configuration.
---
--- Sampling parameters are deliberately not part of it: they do not change what
--- the paragraph means, and including them would invalidate the whole cache the
--- first time anyone nudged the temperature.
---
--- `block_type` is hashed alongside the five components spec §6.1 lists. It is
--- there to close the collision the same section is worried about from the other
--- side: two blocks of *different* types can otherwise land on one key, because
--- one is normalized and the other is not. A prose block written
--- `- a` / `- b` normalizes to `- a - b`, which is byte-identical to a
--- single-line list — different content, different translation, same key. The
--- cost is a missed hit when the very same bytes appear as two different block
--- types, which is the cheaper mistake.
function M.key(opts)
  return digest(join(
    M.key_source(opts.text, opts.block_type),
    opts.block_type,
    opts.target_lang,
    opts.provider,
    opts.model,
    opts.prompt_fp
  ))
end

local Store = {}
Store.__index = Store

--- @param dir string cache root; created lazily on first write
function M.new(dir)
  return setmetatable({ dir = dir }, Store)
end

function Store:_path(key)
  return ('%s/%s/%s.json'):format(self.dir, key:sub(1, 2), key:sub(3))
end

local function read_file(path)
  local fd = uv.fs_open(path, 'r', 438)
  if fd == nil then
    return nil
  end
  local stat = uv.fs_fstat(fd)
  local data = stat and uv.fs_read(fd, stat.size, 0) or nil
  uv.fs_close(fd)
  return data
end

--- @return table|nil entry, nil on a miss, on unreadable/corrupt data, or on an
--- entry written by a newer format version
function Store:get(key)
  local path = self:_path(key)
  local raw = read_file(path)
  if raw == nil then
    return nil
  end

  local ok, entry = pcall(vim.json.decode, raw)
  if not ok or type(entry) ~= 'table' or entry.v ~= FORMAT_VERSION or type(entry.dst) ~= 'string' then
    return nil
  end

  -- Unconditional: mtime is the only eviction ordering we can trust, and it has
  -- to be correct from the first hit, not from the day max_bytes is enabled.
  local now = os.time()
  uv.fs_utime(path, now, now)

  return entry
end

--- Only ever called with a *complete* translation — a partial stream cannot be
--- resumed, so it never becomes an entry (spec §6.5).
function Store:put(key, fields)
  local shard = ('%s/%s'):format(self.dir, key:sub(1, 2))
  vim.fn.mkdir(shard, 'p')

  local entry = {
    v = FORMAT_VERSION,
    src = fields.src,
    dst = fields.dst,
    lang = fields.lang,
    provider = fields.provider,
    model = fields.model,
    prompt_fp = fields.prompt_fp,
    created_at = fields.created_at or os.time(),
  }

  local tmp = ('%s/%s.%d.%d.tmp'):format(shard, key:sub(3), uv.os_getpid(), math.random(1e9))
  local fd = uv.fs_open(tmp, 'w', 384) -- 0600
  if fd == nil then
    return false
  end
  uv.fs_write(fd, vim.json.encode(entry), 0)
  uv.fs_close(fd)

  -- POSIX guarantees rename is atomic within a filesystem, and the temp file
  -- lives in the shard it will land in — so racing writers can never expose a
  -- torn file, and they were writing identical bytes anyway.
  local ok = uv.fs_rename(tmp, self:_path(key))
  if not ok then
    uv.fs_unlink(tmp)
    return false
  end
  return true
end

--- Walk every entry file, yielding `(path, stat, entry|nil)`.
function Store:_each(fn)
  local shards = uv.fs_scandir(self.dir)
  if shards == nil then
    return
  end
  while true do
    local shard, shard_type = uv.fs_scandir_next(shards)
    if shard == nil then
      break
    end
    if shard_type == 'directory' then
      local files = uv.fs_scandir(('%s/%s'):format(self.dir, shard))
      while files ~= nil do
        local name = uv.fs_scandir_next(files)
        if name == nil then
          break
        end
        if name:sub(-5) == '.json' then
          local path = ('%s/%s/%s'):format(self.dir, shard, name)
          local stat = uv.fs_stat(path)
          if stat ~= nil then
            local raw = read_file(path)
            local ok, entry = pcall(vim.json.decode, raw or '')
            fn(path, stat, ok and type(entry) == 'table' and entry or nil)
          end
        end
      end
    end
  end
end

function Store:stats()
  local s = { count = 0, bytes = 0, by_model = {}, by_lang = {} }
  self:_each(function(_, stat, entry)
    s.count = s.count + 1
    s.bytes = s.bytes + stat.size
    if entry ~= nil then
      local model, lang = entry.model or '?', entry.lang or '?'
      s.by_model[model] = (s.by_model[model] or 0) + 1
      s.by_lang[lang] = (s.by_lang[lang] or 0) + 1
    end
  end)
  return s
end

--- @param model string|nil clear only this model's entries; nil clears all
--- @return integer removed
function Store:clear(model)
  local removed = 0
  self:_each(function(path, _, entry)
    if model == nil or (entry ~= nil and entry.model == model) then
      if uv.fs_unlink(path) then
        removed = removed + 1
      end
    end
  end)
  return removed
end

--- @param max_bytes integer|nil nil disables eviction entirely (the default)
--- @return integer removed
function Store:evict(max_bytes)
  if max_bytes == nil then
    return 0
  end

  local files, total = {}, 0
  self:_each(function(path, stat)
    files[#files + 1] = { path = path, size = stat.size, mtime = stat.mtime.sec }
    total = total + stat.size
  end)

  table.sort(files, function(a, b)
    return a.mtime < b.mtime
  end)

  local removed = 0
  for _, f in ipairs(files) do
    if total <= max_bytes then
      break
    end
    if uv.fs_unlink(f.path) then
      total = total - f.size
      removed = removed + 1
    end
  end
  return removed
end

return M
