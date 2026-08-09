--- User commands. Note what is *not* here: there is no `:Translate`, because
--- translation cannot be started by a command — a user typing `:Translate` would
--- expect the paragraph under the cursor and get a usage error (spec §9.3).
local M = {}

local cache = require('translate.cache')
local config = require('translate.config')
local errors = require('translate.errors')

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'translate.nvim' })
end

local function store()
  return cache.new(config.get().cache.dir)
end

local function human_size(bytes)
  local units = { 'B', 'KB', 'MB', 'GB' }
  local value, unit = bytes, 1
  while value >= 1024 and unit < #units do
    value, unit = value / 1024, unit + 1
  end
  return ('%.1f %s'):format(value, units[unit])
end

local function sorted_pairs(tbl)
  local names = vim.tbl_keys(tbl)
  table.sort(names)
  return names
end

function M.stats()
  local s = store():stats()
  local lines = { ('缓存条目 %d 条，共 %s'):format(s.count, human_size(s.bytes)) }

  if s.count > 0 then
    table.insert(lines, '按模型：')
    for _, model in ipairs(sorted_pairs(s.by_model)) do
      table.insert(lines, ('  %s  %d'):format(model, s.by_model[model]))
    end
    table.insert(lines, '按目标语言：')
    for _, lang in ipairs(sorted_pairs(s.by_lang)) do
      table.insert(lines, ('  %s  %d'):format(lang, s.by_lang[lang]))
    end
  end

  notify(table.concat(lines, '\n'))
end

function M.clear(model)
  if model == nil or model == '' then
    local answer = vim.fn.confirm('清空全部翻译缓存？', '&Yes\n&No', 2, 'Question')
    if answer ~= 1 then
      return notify('已取消')
    end
    return notify(('已清空 %d 条缓存'):format(store():clear()))
  end
  notify(('已清除模型 %s 的 %d 条缓存'):format(model, store():clear(model)))
end

--- One minimal, real request through the effective configuration, reporting the
--- error class and the time to first byte.
---
--- Bypasses the cache in both directions: a fixed probe on the normal path
--- would hit instantly on the second run and report success having tested
--- nothing — the worst kind of false positive (§9.3).
function M.ping()
  local translate = require('translate')
  local engine, err = translate._engine()
  if engine == nil then
    return notify(errors.format(err, ('Ping 失败（%s）'):format(err.class)), vim.log.levels.ERROR)
  end

  local started = vim.uv.hrtime()
  local first_byte = nil

  engine:request({
    text = 'The quick brown fox jumps over the lazy dog.',
    block_type = 'paragraph',
    range = { 0, 0 },
  }, {
    on_chunk = function()
      first_byte = first_byte or (vim.uv.hrtime() - started) / 1e6
    end,
    on_done = function()
      notify(
        ('Ping 成功：%s · %s，首字节 %.0f ms'):format(
          engine.provider.name,
          engine.provider.model,
          first_byte or 0
        )
      )
    end,
    on_error = function(ping_err)
      notify(errors.format(ping_err, ('Ping 失败（%s）'):format(ping_err.class)), vim.log.levels.ERROR)
    end,
  }, { bypass_cache = true })
end

function M.setup()
  vim.api.nvim_create_user_command('TranslateCacheStats', function()
    M.stats()
  end, { desc = '翻译缓存统计' })

  vim.api.nvim_create_user_command('TranslateCacheClear', function(opts)
    M.clear(opts.args)
  end, {
    nargs = '?',
    desc = '清除翻译缓存（无参数全清，带参数按模型清）',
    complete = function()
      return sorted_pairs(store():stats().by_model)
    end,
  })

  vim.api.nvim_create_user_command('TranslatePing', function()
    M.ping()
  end, { desc = '用生效配置发一次最小真实请求' })
end

return M
