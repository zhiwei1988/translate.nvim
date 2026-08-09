local eq = MiniTest.expect.equality

local root = vim.g.translate_test_root
local FAKE_CURL = root .. '/tests/fixtures/fake_curl'

local config = require('translate.config')
local keys = require('translate.provider.keys')

local tmp, reported, original_health

--- Collect what the check reported instead of rendering a health buffer.
local function run(over)
  config.reset()
  config.setup(vim.tbl_deep_extend('force', {
    provider = 'deepseek',
    cache = { dir = tmp .. '/cache' },
    request = { curl = FAKE_CURL },
  }, over or {}))

  reported = {}
  local function record(kind)
    return function(msg, extra)
      table.insert(reported, { kind = kind, msg = tostring(msg), extra = extra })
    end
  end

  original_health = vim.health
  vim.health = {
    start = record('start'),
    ok = record('ok'),
    warn = record('warn'),
    error = record('error'),
    info = record('info'),
  }

  local ok, err = pcall(require('translate.health').check)
  vim.health = original_health
  assert(ok, err)

  return reported
end

local function text()
  return table.concat(
    vim.tbl_map(function(r)
      return r.kind .. ' ' .. r.msg .. ' ' .. vim.inspect(r.extra or {})
    end, reported),
    '\n'
  )
end

local function kinds_matching(pattern)
  local out = {}
  for _, r in ipairs(reported) do
    if r.msg:find(pattern) ~= nil then
      table.insert(out, r.kind)
    end
  end
  return out
end

describe('checkhealth translate (§9.4)', function()
  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. '/cache', 'p')
    keys.clear_cache()
    vim.env.DEEPSEEK_API_KEY = nil
    vim.env.GEMINI_API_KEY = nil
    vim.env.TRANSLATE_FAKE_CURL_ARGV = tmp .. '/argv'
  end)

  after_each(function()
    vim.env.DEEPSEEK_API_KEY = nil
    vim.env.GEMINI_API_KEY = nil
    vim.env.TRANSLATE_FAKE_CURL_ARGV = nil
    vim.fn.delete(tmp, 'rf')
    config.reset()
  end)

  -- The community contract for :checkhealth is fast and side-effect free; real
  -- probing is what :TranslatePing is for. It has to work on a plane.
  it('makes no network request at all', function()
    vim.env.DEEPSEEK_API_KEY = 'sk-abcdef'
    run()

    local argv = vim.fn.filereadable(tmp .. '/argv') == 1 and vim.fn.readfile(tmp .. '/argv') or {}
    for _, arg in ipairs(argv) do
      eq(arg:find('http', 1, true), nil)
      eq(arg:find('api.deepseek', 1, true), nil)
    end
    eq(vim.tbl_contains(argv, '--version') or #argv == 0, true)
  end)

  it('checks the Neovim floor, curl and the markdown parser', function()
    run()
    local out = text()
    eq(out:find('Neovim', 1, true) ~= nil, true)
    eq(out:find('curl', 1, true) ~= nil, true)
    eq(out:find('markdown', 1, true) ~= nil, true)
  end)

  -- §3's whole structure story rests on this parser; a trimmed build degrades
  -- to blank-line scanning *silently*.
  it('reports the markdown parser as available in this environment', function()
    run()
    eq(vim.tbl_contains(kinds_matching('markdown treesitter'), 'ok'), true)
  end)

  it('errors when the effective provider has no key', function()
    run()
    eq(vim.tbl_contains(kinds_matching('DEEPSEEK_API_KEY'), 'error'), true)
  end)

  it('accepts the effective provider once its key is present', function()
    vim.env.DEEPSEEK_API_KEY = 'sk-abcdef'
    run()
    eq(vim.tbl_contains(kinds_matching('DEEPSEEK_API_KEY'), 'error'), false)
  end)

  -- Knowing whether the *other* provider would work matters before you edit the
  -- config and restart, not after.
  it('reports other presets as info rather than failures', function()
    vim.env.DEEPSEEK_API_KEY = 'sk-abcdef'
    vim.env.GEMINI_API_KEY = 'gm-123456'
    run()
    local kinds = kinds_matching('GEMINI_API_KEY')
    eq(#kinds > 0, true)
    eq(vim.tbl_contains(kinds, 'error'), false)
    eq(vim.tbl_contains(kinds, 'info'), true)
  end)

  it('never prints any part of a key, not even a prefix', function()
    vim.env.DEEPSEEK_API_KEY = 'sk-supersecretvalue'
    vim.env.GEMINI_API_KEY = 'gm-anothersecret'
    run()
    local out = text()
    eq(out:find('supersecret', 1, true), nil)
    eq(out:find('anothersecret', 1, true), nil)
    eq(out:find('sk-', 1, true), nil)
    eq(out:find('gm-', 1, true), nil)
  end)

  -- Not evaluating it would mean not checking it; the warm cache is a bonus.
  it('evaluates a callable key so the check is a real one', function()
    local calls = 0
    run({
      api_key = function()
        calls = calls + 1
        return 'sk-fromfunction'
      end,
    })
    eq(calls, 1)
    eq(text():find('fromfunction', 1, true), nil)
  end)

  it('reports a callable key that fails as an error', function()
    run({
      api_key = function()
        error('vault locked')
      end,
    })
    eq(vim.tbl_contains(kinds_matching('API key'), 'error'), true)
  end)

  it('reports the cache directory with its entry count', function()
    run()
    eq(text():find('缓存', 1, true) ~= nil, true)
  end)

  it('summarises the effective configuration', function()
    vim.env.DEEPSEEK_API_KEY = 'sk-abcdef'
    run({ model = 'deepseek-v9', target_lang = 'Cantonese' })
    local out = text()
    eq(out:find('deepseek-v9', 1, true) ~= nil, true)
    eq(out:find('Cantonese', 1, true) ~= nil, true)
  end)

  -- The escape hatch silently deletes the correctness constraints (fenced
  -- blocks verbatim, output only the translation, ignore embedded instructions)
  -- along with the stylistic ones (§4.4).
  it('warns when the whole prompt has been replaced', function()
    vim.env.DEEPSEEK_API_KEY = 'sk-abcdef'
    run({ system_prompt = 'Just translate.' })
    eq(vim.tbl_contains(kinds_matching('system_prompt'), 'warn'), true)
  end)

  it('does not warn about the prompt when only extra_instructions is used', function()
    vim.env.DEEPSEEK_API_KEY = 'sk-abcdef'
    run({ extra_instructions = 'Prefer 台湾 terminology.' })
    eq(vim.tbl_contains(kinds_matching('system_prompt'), 'warn'), false)
  end)
end)
