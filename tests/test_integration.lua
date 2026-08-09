-- End-to-end over the real stack: keymap → detection → scheduler → adapter →
-- a real vim.system() pipe (a fake curl) → float.
local eq = MiniTest.expect.equality
local neq = MiniTest.expect.no_equality

local root = vim.g.translate_test_root
local FAKE_CURL = root .. '/tests/fixtures/fake_curl'

local translate = require('translate')
local config = require('translate.config')
local cache = require('translate.cache')
local keys = require('translate.provider.keys')

local tmp, cache_dir, buf, win

local function scenario(lines)
  local path = tmp .. '/scenario'
  vim.fn.writefile(lines, path)
  vim.env.TRANSLATE_FAKE_CURL_SCRIPT = path
end

local function respond(text)
  scenario({
    'emit data: ' .. vim.json.encode({ choices = { { delta = { content = text } } } }) .. '\\n\\n',
    'emit data: [DONE]\\n\\n',
    'status 200',
  })
end

local function setup(over)
  translate.setup(vim.tbl_deep_extend('force', {
    provider = 'deepseek',
    api_key = 'sk-integration',
    cache = { dir = cache_dir },
    request = { curl = FAKE_CURL },
  }, over or {}))
end

local function open_markdown(text)
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n', { plain = true }))
  vim.bo[buf].filetype = 'markdown'
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  return buf
end

local function float_text()
  local f = translate._float()
  if f == nil or not f:is_open() then
    return nil
  end
  return table.concat(vim.api.nvim_buf_get_lines(f.buf, 0, -1, false), '\n')
end

local function wait_for(fn)
  return vim.wait(10000, fn, 10)
end

--- Wait for the *request* to finish, not merely for text to appear. Closing the
--- float mid-stream starts the grace period instead, and the next request would
--- then rejoin the in-flight one rather than reading the cache.
local function wait_done()
  return wait_for(function()
    local f = translate._float()
    return f ~= nil and f.state ~= 'loading'
  end)
end

local function title()
  return vim.api.nvim_win_get_config(translate._float().win).title[1][1]
end

describe('translate.nvim end to end', function()
  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    cache_dir = tmp .. '/cache'
    vim.env.TRANSLATE_FAKE_CURL_ARGV = tmp .. '/argv'
    vim.env.TRANSLATE_FAKE_CURL_STDIN = tmp .. '/stdin'
    config.reset()
    keys.clear_cache()
    translate._reset()
  end)

  after_each(function()
    translate._reset()
    vim.env.TRANSLATE_FAKE_CURL_SCRIPT = nil
    vim.env.TRANSLATE_FAKE_CURL_ARGV = nil
    vim.env.TRANSLATE_FAKE_CURL_STDIN = nil
    if buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    vim.fn.delete(tmp, 'rf')
  end)

  it('translates the paragraph under the cursor into a float', function()
    setup()
    respond('你好，世界。')
    open_markdown('# Title\n\nHello world.\n\nAnother paragraph.\n')
    vim.api.nvim_win_set_cursor(win, { 3, 0 })

    translate.translate()
    eq(wait_for(function()
      return float_text() == '你好，世界。'
    end), true)
    eq(vim.api.nvim_get_current_win(), win)
  end)

  -- The unit tests hand float.open() its options directly, so only this seam
  -- catches setup() dropping one on the way through.
  it('carries float.max_width from setup() through to the window', function()
    setup({ float = { max_width = 30 } })
    respond('你好，世界。')
    open_markdown('# Title\n\n' .. string.rep('Hello world. ', 20) .. '\n')
    vim.api.nvim_win_set_cursor(win, { 3, 0 })

    translate.translate()
    eq(wait_for(function()
      return float_text() == '你好，世界。'
    end), true)
    eq(vim.api.nvim_win_get_config(translate._float().win).width, 30)
  end)

  it('serves the second request for the same paragraph from the cache', function()
    setup()
    respond('你好，世界。')
    open_markdown('Hello world.\n')
    vim.api.nvim_win_set_cursor(win, { 1, 0 })

    translate.translate()
    eq(wait_done(), true)
    eq(float_text(), '你好，世界。')
    translate._float():close()

    -- The scenario now answers with something else; a cache hit must ignore it.
    respond('DIFFERENT')
    translate.translate()
    eq(float_text(), '你好，世界。')
    eq(title():find('⚡', 1, true) ~= nil, true)
  end)

  it('hits the same cache entry after the paragraph is re-wrapped', function()
    setup()
    respond('你好，世界。')
    open_markdown('Hello\nworld.\n')
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    translate.translate()
    eq(wait_done(), true)
    translate._float():close()

    local before = cache.new(cache_dir):stats().count
    eq(before, 1)

    open_markdown('Hello world.\n')
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    respond('DIFFERENT')
    translate.translate()

    eq(float_text(), '你好，世界。')
    eq(cache.new(cache_dir):stats().count, before)
  end)

  it('refuses a fenced code block with one warning and no request', function()
    setup()
    respond('never sent')
    open_markdown('Prose.\n\n```lua\nlocal x = 1\n```\n')
    vim.api.nvim_win_set_cursor(win, { 4, 0 })

    local notices = {}
    local original = vim.notify
    vim.notify = function(msg, level)
      table.insert(notices, { msg = msg, level = level })
    end
    translate.translate()
    vim.notify = original

    eq(#notices, 1)
    eq(notices[1].level, vim.log.levels.WARN)
    eq(float_text(), nil)
    eq(vim.uv.fs_stat(tmp .. '/argv'), nil) -- curl never ran
  end)

  it('renders an auth failure in plain language', function()
    setup()
    scenario({ 'emit {"error":{"message":"Invalid API key"}}', 'status 401' })
    open_markdown('Hello world.\n')
    vim.api.nvim_win_set_cursor(win, { 1, 0 })

    translate.translate()
    eq(wait_for(function()
      local t = float_text()
      return t ~= nil and t:find('Invalid API key', 1, true) ~= nil
    end), true)
    eq(float_text():find('DEEPSEEK_API_KEY', 1, true) ~= nil, true)
  end)

  it('closes the float when the cursor leaves the paragraph', function()
    setup()
    respond('你好')
    open_markdown('Hello world.\n\nSecond paragraph.\n')
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    translate.translate()
    wait_for(function()
      return float_text() ~= nil
    end)

    vim.api.nvim_win_set_cursor(win, { 3, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    eq(translate._float(), nil)
  end)

  it('translates a visual selection without widening it to whole lines', function()
    setup()
    respond('勇敢的新')
    open_markdown('hello brave new world\n')
    vim.api.nvim_win_set_cursor(win, { 1, 0 })

    translate.translate_selection_range({ 1, 7 }, { 1, 15 }, 'v')
    eq(wait_for(function()
      return float_text() == '勇敢的新'
    end), true)

    local sent = vim.json.decode(table.concat(vim.fn.readfile(tmp .. '/stdin'), '\n'))
    eq(sent.messages[2].content, '<source_text>\nbrave new\n</source_text>')
  end)

  describe('commands (§9.3)', function()
    before_each(function()
      require('translate.commands').setup()
    end)

    -- Users would reach for `:Translate` expecting it to translate the current
    -- paragraph, so it must not exist at all rather than mean something else.
    it('does not define a bare :Translate', function()
      eq(vim.api.nvim_get_commands({})['Translate'], nil)
      eq(pcall(vim.cmd, 'Translate'), false)
    end)

    it('defines the cache and ping commands', function()
      eq(vim.fn.exists(':TranslateCacheClear'), 2)
      eq(vim.fn.exists(':TranslateCacheStats'), 2)
      eq(vim.fn.exists(':TranslatePing'), 2)
    end)

    -- A fixed probe that went through the cache would hit on the second run and
    -- report "all good" having measured nothing.
    it('runs a real request on every ping and caches nothing', function()
      setup()
      respond('probe')
      local store = cache.new(cache_dir)

      local notices = {}
      local original = vim.notify
      vim.notify = function(msg)
        table.insert(notices, msg)
      end

      vim.cmd('TranslatePing')
      eq(wait_for(function()
        return #notices >= 1
      end), true)
      local after_first = store:stats().count

      vim.cmd('TranslatePing')
      eq(wait_for(function()
        return #notices >= 2
      end), true)
      vim.notify = original

      eq(after_first, 0)
      eq(store:stats().count, 0)
      eq(notices[2]:find('ms', 1, true) ~= nil, true) -- reports first-byte latency
    end)

    it('reports cache statistics', function()
      setup()
      cache.new(cache_dir):put('aa11', {
        src = 'x',
        dst = 'y',
        lang = 'Chinese',
        provider = 'deepseek',
        model = 'deepseek-v4-flash',
      })

      local notices = {}
      local original = vim.notify
      vim.notify = function(msg)
        table.insert(notices, msg)
      end
      vim.cmd('TranslateCacheStats')
      vim.notify = original

      eq(notices[1]:find('deepseek-v4-flash', 1, true) ~= nil, true)
      eq(notices[1]:find('Chinese', 1, true) ~= nil, true)
    end)

    it('clears a single model without touching the others', function()
      setup()
      local store = cache.new(cache_dir)
      store:put('aa11', { src = 'x', dst = 'y', lang = 'Chinese', provider = 'p', model = 'old-model' })
      store:put('bb22', { src = 'x', dst = 'y', lang = 'Chinese', provider = 'p', model = 'new-model' })

      local original = vim.notify
      vim.notify = function() end
      vim.cmd('TranslateCacheClear old-model')
      vim.notify = original

      eq(store:stats().count, 1)
      eq(store:stats().by_model['new-model'], 1)
    end)
  end)

  describe('<Plug> mappings (§9.2)', function()
    it('defines both mappings and no default global keys', function()
      vim.cmd('source ' .. root .. '/plugin/translate.lua')
      eq(vim.fn.maparg('<Plug>(translate)', 'n') ~= '', true)
      eq(vim.fn.maparg('<Plug>(translate-selection)', 'x') ~= '', true)
      eq(vim.fn.maparg('<Leader>tt', 'n'), '')
      eq(vim.fn.maparg('gt', 'n'), '')
    end)

    -- The selection mapping must not leave visual mode before reading the
    -- selection, or the columns are a selection old.
    it('reads the selection with <Cmd>, which keeps visual mode intact', function()
      vim.cmd('source ' .. root .. '/plugin/translate.lua')
      eq(vim.fn.maparg('<Plug>(translate-selection)', 'x'):find('<Cmd>', 1, true) ~= nil, true)
    end)
  end)
end)
