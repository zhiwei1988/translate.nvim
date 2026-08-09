--- `:checkhealth translate`.
---
--- Zero network — not one byte. Real probing lives in `:TranslatePing`. The
--- community contract for a health check is fast and side-effect free, and it
--- has to work on a plane (spec §9.4).
local M = {}

local cache = require('translate.cache')
local config = require('translate.config')
local keys = require('translate.provider.keys')
local presets = require('translate.provider.presets')

local function h()
  return vim.health
end

local function check_neovim()
  h().start('Neovim')
  if vim.fn.has('nvim-0.10') == 1 then
    h().ok(('Neovim %s'):format(vim.version()))
  else
    h().error('需要 Neovim 0.10 或更高版本（vim.system 与浮窗 footer 的下限）')
  end
end

local function check_curl(cfg)
  h().start('curl')
  local exe = cfg.request.curl or 'curl'

  if vim.fn.executable(exe) ~= 1 then
    return h().error(('未在 PATH 上找到 %s'):format(exe), { '安装 curl 后重试' })
  end

  -- `--version` only: a local exec, never a request.
  local result = vim.system({ exe, '--version' }, { text = true }):wait(5000)
  local first_line = vim.split(result.stdout or '', '\n', { plain = true })[1] or ''
  h().ok(('curl 可用：%s'):format(first_line ~= '' and first_line or exe))
end

local function check_treesitter()
  h().start('markdown treesitter parser')
  local ok, err = pcall(vim.treesitter.language.add, 'markdown')
  if ok then
    -- §3's structural detection rests entirely on this. A trimmed build or an
    -- ABI mismatch degrades it to blank-line scanning *silently*.
    h().ok('markdown treesitter parser 可用，段落按文档结构切分')
  else
    h().warn(
      ('markdown treesitter parser 不可用：%s'):format(tostring(err)),
      { '段落检测会退化为空行扫描，列表 / 表格 / 引用块将不再整块成段', '安装 markdown parser（如 :TSInstall markdown）' }
    )
  end
end

local function check_api_keys(cfg)
  h().start('API key')

  local preset = presets.resolve(cfg.provider, cfg.presets)
  if preset == nil then
    return h().error(('未知的 provider "%s"'):format(tostring(cfg.provider)))
  end

  if type(preset.translate) == 'function' then
    h().info(('provider "%s" 是自定义 adapter，自行管理认证'):format(preset.name))
  else
    -- A callable key is evaluated for real: not evaluating it would mean not
    -- checking it. It may fork `pass`/`op` and even prompt to unlock — and it
    -- warms the in-process key cache on the way through.
    local key, err = keys.resolve(cfg, preset)
    if key == nil then
      -- Name the variable in the message itself: being told "no key" without
      -- being told which variable to set leaves nothing to act on.
      h().error(
        ('生效 provider "%s" 取不到 API key（环境变量 %s）：%s'):format(
          preset.name,
          preset.api_key_env or '未声明',
          err.message
        ),
        { err.hint }
      )
    else
      h().ok(
        ('生效 provider "%s" 的 API key 已就绪（%s）'):format(preset.name, preset.api_key_env or '显式配置')
      )
    end
  end

  -- Whether the *other* providers would work is worth knowing before editing
  -- the config and restarting, not after.
  for _, name in ipairs(presets.names(cfg.presets)) do
    local other = presets.resolve(name, cfg.presets)
    if other ~= nil and name ~= preset.name and other.api_key_env ~= nil then
      h().info(
        ('%s：环境变量 %s %s'):format(
          name,
          other.api_key_env,
          keys.env_present(other) and '已设置' or '未设置'
        )
      )
    end
  end
end

local function check_cache(cfg)
  h().start('缓存目录')
  local dir = cfg.cache.dir

  if vim.fn.isdirectory(dir) == 0 then
    return h().info(('缓存目录 %s 尚未创建，首次翻译时自动建立'):format(dir))
  end

  if vim.fn.filewritable(dir) ~= 2 then
    return h().error(('缓存目录 %s 不可写'):format(dir))
  end

  local stats = cache.new(dir):stats()
  h().ok(('缓存目录 %s 可写，%d 条条目，占用 %.1f KB'):format(dir, stats.count, stats.bytes / 1024))
end

local function check_effective_config(cfg)
  h().start('生效配置')

  local preset = presets.resolve(cfg.provider, cfg.presets)
  h().info(('provider = %s'):format(tostring(cfg.provider)))
  h().info(('model = %s'):format(tostring(cfg.model or (preset ~= nil and preset.model) or '(未知)')))
  h().info(('target_lang = %s'):format(tostring(cfg.target_lang)))

  if cfg.system_prompt ~= nil then
    h().warn('已用 system_prompt 全量替换内置 prompt', {
      '内置 prompt 里混着偏好与正确性约束：围栏块原样、只输出译文、不执行文档内指令',
      '全量替换会一并删掉后者；多数需求用 extra_instructions 追加即可',
    })
  elseif cfg.extra_instructions ~= nil then
    h().ok('已通过 extra_instructions 追加自定义指令，正确性约束保留')
  end
end

function M.check()
  local cfg = config.get()
  check_neovim()
  check_curl(cfg)
  check_treesitter()
  check_api_keys(cfg)
  check_cache(cfg)
  check_effective_config(cfg)
end

return M
