local eq = MiniTest.expect.equality
local neq = MiniTest.expect.no_equality
local keys = require('translate.provider.keys')
local provider = require('translate.provider')

describe('api key resolution (§5.6)', function()
  before_each(function()
    keys.clear_cache()
    vim.env.DEEPSEEK_API_KEY = nil
    vim.env.TRANSLATE_TEST_KEY = nil
  end)

  after_each(function()
    vim.env.DEEPSEEK_API_KEY = nil
    vim.env.TRANSLATE_TEST_KEY = nil
  end)

  local preset = { name = 'deepseek', api_key_env = 'DEEPSEEK_API_KEY' }

  it('reads the environment variable the preset declares', function()
    vim.env.DEEPSEEK_API_KEY = 'from-env'
    eq(keys.resolve({}, preset), 'from-env')
  end)

  it('lets an explicit setup() key win over the environment', function()
    vim.env.DEEPSEEK_API_KEY = 'from-env'
    eq(keys.resolve({ api_key = 'explicit' }, preset), 'explicit')
  end)

  it('lets a preset override which environment variable is read', function()
    vim.env.TRANSLATE_TEST_KEY = 'other-env'
    eq(keys.resolve({}, { name = 'x', api_key_env = 'TRANSLATE_TEST_KEY' }), 'other-env')
  end)

  it('ignores an empty environment variable', function()
    vim.env.DEEPSEEK_API_KEY = ''
    local key, err = keys.resolve({}, preset)
    eq(key, nil)
    eq(err.class, 'auth')
  end)

  -- Callable keys usually shell out to `pass` or `op`; forking per request
  -- would make every translation pay for it.
  it('evaluates a function key exactly once and caches the result', function()
    local calls = 0
    local cfg = {
      api_key = function()
        calls = calls + 1
        return 'lazy-key'
      end,
    }
    eq(keys.resolve(cfg, preset), 'lazy-key')
    eq(keys.resolve(cfg, preset), 'lazy-key')
    eq(keys.resolve(cfg, preset), 'lazy-key')
    eq(calls, 1)
  end)

  it('re-evaluates after the cache is cleared, so keys can be rotated', function()
    local calls = 0
    local cfg = {
      api_key = function()
        calls = calls + 1
        return 'k' .. calls
      end,
    }
    eq(keys.resolve(cfg, preset), 'k1')
    keys.clear_cache()
    eq(keys.resolve(cfg, preset), 'k2')
  end)

  it('reports a function that fails as an auth error rather than throwing', function()
    local key, err = keys.resolve({
      api_key = function()
        error('vault locked')
      end,
    }, preset)
    eq(key, nil)
    eq(err.class, 'auth')
    eq(err.message:find('vault locked', 1, true) ~= nil, true)
  end)

  -- Being told "no key" without being told *which variable to set* leaves the
  -- user with nothing to do.
  it('names the environment variable to set when no key is found', function()
    local key, err = keys.resolve({}, preset)
    eq(key, nil)
    eq(err.class, 'auth')
    eq(err.hint:find('DEEPSEEK_API_KEY', 1, true) ~= nil, true)
  end)

  it('reports whether an environment variable is present without revealing it', function()
    vim.env.DEEPSEEK_API_KEY = 'sk-abcdef123456'
    eq(keys.env_present(preset), true)
    vim.env.DEEPSEEK_API_KEY = nil
    eq(keys.env_present(preset), false)
  end)
end)

describe('provider registry (§5.7)', function()
  before_each(function()
    keys.clear_cache()
    vim.env.DEEPSEEK_API_KEY = 'sk-test'
  end)

  after_each(function()
    vim.env.DEEPSEEK_API_KEY = nil
  end)

  it('builds a provider from a builtin preset', function()
    local p, err = provider.resolve({ provider = 'deepseek' })
    eq(err, nil)
    eq(p.name, 'deepseek')
    eq(type(p.translate), 'function')
  end)

  it('defaults the model to the preset default', function()
    eq(provider.resolve({ provider = 'deepseek' }).model, 'deepseek-v4-flash')
  end)

  -- deepseek-chat / deepseek-reasoner were retired on 2026-07-24; a hardcoded
  -- model name is a time bomb, so it has to stay configurable.
  it('lets setup() override the model', function()
    eq(provider.resolve({ provider = 'deepseek', model = 'deepseek-v9' }).model, 'deepseek-v9')
  end)

  -- A preset that declares no environment variable is declaring that the
  -- service needs no credential — a local Ollama should not demand that the
  -- user invent a dummy key.
  it('accepts a user-registered preset that needs no credential', function()
    local p, err = provider.resolve({
      provider = 'ollama',
      presets = { ollama = { base_url = 'http://localhost:11434/v1', model = 'qwen3' } },
    })
    eq(err, nil)
    eq(p.name, 'ollama')
    eq(p.model, 'qwen3')
  end)

  it('still demands a key from a preset that declares one', function()
    local p, err = provider.resolve({
      provider = 'paid',
      presets = { paid = { base_url = 'https://x', model = 'm', api_key_env = 'TRANSLATE_ABSENT_KEY' } },
    })
    eq(p, nil)
    eq(err.class, 'auth')
    eq(err.hint:find('TRANSLATE_ABSENT_KEY', 1, true) ~= nil, true)
  end)

  -- §5.7: a full adapter is the second extension point.
  it('accepts a user-supplied full adapter', function()
    local called = false
    local p = provider.resolve({
      provider = 'custom',
      presets = {
        custom = {
          model = 'x',
          translate = function()
            called = true
            return { abort = function() end }
          end,
        },
      },
    })
    p.translate({}, {})
    eq(called, true)
  end)

  it('reports an unknown provider name instead of failing silently', function()
    local p, err = provider.resolve({ provider = 'nope' })
    eq(p, nil)
    neq(err, nil)
    eq(err.message:find('nope', 1, true) ~= nil, true)
  end)

  it('reports a missing key as an auth error', function()
    vim.env.DEEPSEEK_API_KEY = nil
    local p, err = provider.resolve({ provider = 'deepseek' })
    eq(p, nil)
    eq(err.class, 'auth')
  end)

  it('does not require a key for a custom adapter that handles its own auth', function()
    vim.env.DEEPSEEK_API_KEY = nil
    local p, err = provider.resolve({
      provider = 'custom',
      presets = { custom = { model = 'x', translate = function() end } },
    })
    eq(err, nil)
    neq(p, nil)
  end)
end)
