local eq = MiniTest.expect.equality
local neq = MiniTest.expect.no_equality
local openai = require('translate.provider.openai')
local presets = require('translate.provider.presets')

local root = vim.g.translate_test_root
local FAKE_CURL = root .. '/tests/fixtures/fake_curl'

local tmp, dumps

local function scenario(lines)
  local path = tmp .. '/scenario'
  vim.fn.writefile(lines, path)
  vim.env.TRANSLATE_FAKE_CURL_SCRIPT = path
  return path
end

local function sse_lines(deltas)
  local out = {}
  for _, d in ipairs(deltas) do
    out[#out + 1] = 'emit data: ' .. vim.json.encode(d) .. '\\n\\n'
  end
  out[#out + 1] = 'emit data: [DONE]\\n\\n'
  out[#out + 1] = 'status 200'
  return out
end

local function text_deltas(texts)
  return vim.tbl_map(function(t)
    return { choices = { { delta = { content = t } } } }
  end, texts)
end

local function provider(over)
  return openai.new(vim.tbl_extend('force', {
    preset = presets.builtin.deepseek,
    api_key = 'sk-secret-key',
    curl = FAKE_CURL,
  }, over or {}))
end

local function run(p, req)
  local r = { chunks = {}, done = false, err = nil }
  r.handle = p.translate(
    vim.tbl_extend('force', {
      text = '<source_text>\nHello.\n</source_text>',
      system = 'SYSTEM PROMPT',
      model = 'deepseek-v4-flash',
      temperature = 0.3,
      thinking = false,
    }, req or {}),
    {
      on_chunk = function(d)
        r.chunks[#r.chunks + 1] = d
      end,
      on_done = function()
        r.done = true
      end,
      on_error = function(e)
        r.err = e
      end,
    }
  )
  vim.wait(15000, function()
    return r.done or r.err ~= nil
  end, 5)
  r.text = table.concat(r.chunks)
  return r
end

local function read(path)
  return table.concat(vim.fn.readfile(path), '\n')
end

local function body()
  return vim.json.decode(read(dumps.stdin))
end

local function argv()
  return vim.fn.readfile(dumps.argv)
end

describe('openai adapter', function()
  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    dumps = { argv = tmp .. '/argv', stdin = tmp .. '/stdin', config = tmp .. '/config' }
    vim.env.TRANSLATE_FAKE_CURL_ARGV = dumps.argv
    vim.env.TRANSLATE_FAKE_CURL_STDIN = dumps.stdin
    vim.env.TRANSLATE_FAKE_CURL_CONFIG = dumps.config
  end)

  after_each(function()
    for _, k in ipairs({ 'SCRIPT', 'ARGV', 'STDIN', 'CONFIG' }) do
      vim.env['TRANSLATE_FAKE_CURL_' .. k] = nil
    end
    vim.fn.delete(tmp, 'rf')
  end)

  describe('streaming', function()
    it('reports text deltas, not accumulated values', function()
      scenario(sse_lines(text_deltas({ '你好', '，', '世界' })))
      local r = run(provider())
      eq(r.chunks, { '你好', '，', '世界' })
      eq(r.done, true)
      eq(r.err, nil)
    end)

    it('survives a frame split across read boundaries', function()
      scenario({
        'emit data: {"choices":[{"delta":{"con',
        'sleep 0.05',
        'emit tent":"hi"}}]}\\n\\n',
        'emit data: [DONE]\\n\\n',
        'status 200',
      })
      eq(run(provider()).text, 'hi')
    end)

    -- §5.3: reasoning is dropped, but the branch must be explicit — silently
    -- concatenating it into the translation is the failure this guards.
    it('never lets reasoning_content reach the translation', function()
      scenario(sse_lines({
        { choices = { { delta = { reasoning_content = 'Let me think about this...' } } } },
        { choices = { { delta = { content = '你好' } } } },
        { choices = { { delta = { reasoning_content = 'more thinking' } } } },
        { choices = { { delta = { content = '世界' } } } },
      }))
      local r = run(provider())
      eq(r.text, '你好世界')
      eq(r.text:find('think', 1, true), nil)
    end)

    it('ignores a delta that carries neither content nor reasoning', function()
      scenario(sse_lines({
        { choices = { { delta = { role = 'assistant' } } } },
        { choices = { { delta = { content = 'x' } } } },
        { choices = { { finish_reason = 'stop', delta = vim.empty_dict() } } },
      }))
      eq(run(provider()).text, 'x')
    end)

    it('ignores an unparseable frame instead of aborting the stream', function()
      scenario({
        'emit data: {"choices":[{"delta":{"content":"a"}}]}\\n\\n',
        'emit data: not json at all\\n\\n',
        'emit data: {"choices":[{"delta":{"content":"b"}}]}\\n\\n',
        'emit data: [DONE]\\n\\n',
        'status 200',
      })
      eq(run(provider()).text, 'ab')
    end)

    it('completes when the process ends cleanly without an explicit [DONE]', function()
      scenario({
        'emit data: {"choices":[{"delta":{"content":"a"}}]}\\n\\n',
        'status 200',
      })
      local r = run(provider())
      eq(r.text, 'a')
      eq(r.done, true)
    end)

    -- The headers said 200, so the status code alone looks like success — but
    -- curl exited non-zero, meaning the body was cut off mid-stream. Reporting
    -- completion here hands the scheduler a truncated translation, which it
    -- then caches forever (§6.5: only complete translations are cached).
    it('treats a stream cut short by a transport failure as an error', function()
      scenario({
        'emit data: {"choices":[{"delta":{"content":"HALF"}}]}\\n\\n',
        'status 200',
        'exitcode 56',
      })
      local r = run(provider())
      eq(r.text, 'HALF')
      eq(r.done, false)
      eq(r.err.class, 'network')
    end)
  end)

  describe('reasoning is dropped, the translation is not (§5.3)', function()
    it('keeps content that shares a frame with reasoning_content', function()
      scenario(sse_lines({
        { choices = { { delta = { reasoning_content = 'still thinking', content = '你好' } } } },
        { choices = { { delta = { content = '世界' } } } },
      }))
      local r = run(provider())
      eq(r.text, '你好世界')
    end)

    -- Transition frames routinely carry an empty reasoning field next to real
    -- content; treating "is a string" as "is reasoning" loses the translation.
    it('keeps content when reasoning_content is an empty string', function()
      scenario(sse_lines({
        { choices = { { delta = { reasoning_content = '', content = '你好' } } } },
      }))
      eq(run(provider()).text, '你好')
    end)

    it('still drops a frame that is reasoning only', function()
      scenario(sse_lines({
        { choices = { { delta = { reasoning_content = 'pondering' } } } },
        { choices = { { delta = { content = '你好' } } } },
      }))
      local r = run(provider())
      eq(r.text, '你好')
      eq(r.text:find('pondering', 1, true), nil)
    end)
  end)

  describe('request shape (§5.4)', function()
    before_each(function()
      scenario(sse_lines(text_deltas({ 'x' })))
    end)

    it('sends the system prompt rendered upstream and the text verbatim', function()
      run(provider(), { system = 'RENDERED', text = '<source_text>\nHi.\n</source_text>' })
      local b = body()
      eq(b.messages[1].role, 'system')
      eq(b.messages[1].content, 'RENDERED')
      eq(b.messages[2].role, 'user')
      eq(b.messages[2].content, '<source_text>\nHi.\n</source_text>')
    end)

    it('streams and passes temperature through', function()
      run(provider(), { temperature = 0.7 })
      eq(body().stream, true)
      eq(body().temperature, 0.7)
    end)

    -- A truncated translation is far worse than a slow one, so no ceiling.
    it('never sets max_tokens', function()
      run(provider(), { max_tokens = 999 })
      eq(body().max_tokens, nil)
    end)

    it('disables thinking by default the way the preset spells it', function()
      run(provider(), { thinking = false })
      eq(body().thinking, { type = 'disabled' })
    end)

    it('uses the gemini spelling on the gemini preset', function()
      run(provider({ preset = presets.builtin.gemini }), { thinking = false })
      eq(body().reasoning_effort, 'none')
      eq(body().thinking, nil)
    end)

    it('enables thinking when asked', function()
      run(provider(), { thinking = true })
      neq(body().thinking, { type = 'disabled' })
    end)

    it('passes preset extra_body through', function()
      local preset = vim.tbl_extend('force', presets.builtin.deepseek, { extra_body = { top_p = 0.9 } })
      run(provider({ preset = preset }))
      eq(body().top_p, 0.9)
    end)

    -- §5.2: deprecated on DeepSeek; passing them through returns 422.
    it('drops frequency_penalty and presence_penalty on deepseek', function()
      local preset = vim.tbl_extend('force', presets.builtin.deepseek, {
        extra_body = { frequency_penalty = 0.5, presence_penalty = 0.5, top_p = 0.9 },
      })
      run(provider({ preset = preset }))
      eq(body().frequency_penalty, nil)
      eq(body().presence_penalty, nil)
      eq(body().top_p, 0.9)
    end)
  end)

  describe('endpoint and credentials', function()
    before_each(function()
      scenario(sse_lines(text_deltas({ 'x' })))
    end)

    it('posts to the deepseek path, which has no /v1/ segment', function()
      run(provider())
      eq(vim.tbl_contains(argv(), 'https://api.deepseek.com/chat/completions'), true)
    end)

    it('joins the gemini base_url without doubling the slash', function()
      run(provider({ preset = presets.builtin.gemini }))
      eq(
        vim.tbl_contains(argv(), 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions'),
        true
      )
    end)

    -- argv is world-readable via `ps`; the key goes through a 0600 config file.
    it('keeps the api key out of the command line', function()
      run(provider())
      eq(read(dumps.argv):find('sk-secret-key', 1, true), nil)
      eq(read(dumps.config):find('sk-secret-key', 1, true) ~= nil, true)
    end)

    it('sends the key as a bearer token', function()
      run(provider())
      eq(read(dumps.config):find('Authorization: Bearer sk-secret-key', 1, true) ~= nil, true)
    end)

    -- Dropping the header and sending anyway would come back as a 401, and the
    -- user would be told to check an environment variable that was fine all
    -- along.
    it('refuses to send unauthenticated when the credential file cannot be written', function()
      local original = vim.fn.tempname
      vim.fn.tempname = function()
        return '/nonexistent-directory-for-tests/creds'
      end
      local r = run(provider())
      vim.fn.tempname = original

      eq(r.done, false)
      eq(r.err.class, 'auth')
      eq(vim.uv.fs_stat(dumps.argv), nil) -- curl was never spawned
    end)

    it('removes the credential file once the request is over', function()
      run(provider())
      local leftovers = vim.tbl_filter(function(a)
        return a:match('translate%-auth') ~= nil
      end, argv())
      eq(#leftovers, 1)
      eq(vim.uv.fs_stat(leftovers[1]), nil)
    end)
  end)

  describe('error classification (§5.5)', function()
    local function fails_with(status, body_json)
      scenario({
        'emit ' .. (body_json or '{"error":{"message":"boom"}}'),
        'status ' .. status,
      })
      return run(provider()).err
    end

    it('maps 401 to auth with an actionable hint', function()
      local err = fails_with(401)
      eq(err.class, 'auth')
      eq(err.status, 401)
      eq(err.hint:find('DEEPSEEK_API_KEY', 1, true) ~= nil, true)
    end)

    it('maps 402 to quota with somewhere to go', function()
      local err = fails_with(402)
      eq(err.class, 'quota')
      eq(err.hint ~= nil and err.hint ~= '', true)
    end)

    it('maps 429 to rate_limit', function()
      eq(fails_with(429).class, 'rate_limit')
    end)

    it('maps 400 and 422 to bad_request', function()
      eq(fails_with(400).class, 'bad_request')
      eq(fails_with(422).class, 'bad_request')
    end)

    it('maps 500 and 503 to server', function()
      eq(fails_with(500).class, 'server')
      eq(fails_with(503).class, 'server')
    end)

    it('maps a failed connection to network', function()
      scenario({ 'status 000', 'exitcode 7' })
      eq(run(provider()).err.class, 'network')
    end)

    it('extracts the message from a well-formed error body', function()
      eq(fails_with(400, '{"error":{"message":"model not found"}}').message, 'model not found')
    end)

    -- Never lose the server's explanation just because it did not match the
    -- shape we hoped for.
    it('falls back to the whole body when it is not the expected shape', function()
      local err = fails_with(400, '<html>Gateway problem</html>')
      eq(err.message:find('Gateway problem', 1, true) ~= nil, true)
    end)

    it('handles an error body that is valid json but not an error envelope', function()
      local err = fails_with(400, '{"detail":"nope"}')
      eq(err.message:find('nope', 1, true) ~= nil, true)
    end)

    it('treats a 200 that carried no stream at all as a server error', function()
      scenario({ 'emit surprise!', 'status 200' })
      local err = run(provider()).err
      eq(err.class, 'server')
      eq(err.message:find('surprise', 1, true) ~= nil, true)
    end)
  end)

  describe('abort (§5.3)', function()
    it('stops the process and reports neither completion nor error', function()
      scenario({
        'emit data: {"choices":[{"delta":{"content":"a"}}]}\\n\\n',
        'sleep 5',
        'emit data: [DONE]\\n\\n',
        'status 200',
      })

      local r = { chunks = {}, done = false, err = nil }
      local handle = provider().translate(
        { text = 't', system = 's', model = 'm', temperature = 0.3, thinking = false },
        {
          on_chunk = function(d)
            r.chunks[#r.chunks + 1] = d
          end,
          on_done = function()
            r.done = true
          end,
          on_error = function(e)
            r.err = e
          end,
        }
      )

      vim.wait(5000, function()
        return #r.chunks > 0
      end, 5)
      handle.abort()
      vim.wait(1500)

      eq(r.done, false)
      eq(r.err, nil) -- cancellation is not an error
    end)

    it('is safe to call twice', function()
      scenario({ 'sleep 5', 'status 200' })
      local handle = provider().translate(
        { text = 't', system = 's', model = 'm', temperature = 0.3, thinking = false },
        { on_chunk = function() end, on_done = function() end, on_error = function() end }
      )
      handle.abort()
      handle.abort()
      vim.wait(200)
    end)
  end)
end)
