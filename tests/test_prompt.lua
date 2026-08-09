local eq = MiniTest.expect.equality
local neq = MiniTest.expect.no_equality
local prompt = require('translate.prompt')

describe('prompt.render', function()
  it('substitutes the target language and leaves no placeholder behind', function()
    local s = prompt.render({ target_lang = 'Japanese' })
    eq(s:find('Japanese', 1, true) ~= nil, true)
    eq(s:find('{target_lang}', 1, true), nil)
  end)

  it('substitutes every occurrence, not just the first', function()
    local s = prompt.render({ target_lang = 'Traditional Chinese' })
    local n = select(2, s:gsub('Traditional Chinese', ''))
    eq(n >= 3, true)
  end)

  it('does not treat the language as a gsub replacement pattern', function()
    local s = prompt.render({ target_lang = '100% Cantonese' })
    eq(s:find('100% Cantonese', 1, true) ~= nil, true)
  end)

  it('appends extra_instructions at the very end', function()
    local s = prompt.render({ target_lang = 'Chinese', extra_instructions = 'Keep "foo" as-is.' })
    eq(s:sub(-#'Keep "foo" as-is.'), 'Keep "foo" as-is.')
  end)

  it('replaces the whole template when system_prompt is set', function()
    local s = prompt.render({ target_lang = 'Chinese', system_prompt = 'Only translate.' })
    eq(s, 'Only translate.')
    eq(s:find('translation engine', 1, true), nil)
  end)

  -- §4.4: the two extension points are orthogonal.
  it('still appends extra_instructions on top of a replaced template', function()
    local s = prompt.render({
      target_lang = 'Chinese',
      system_prompt = 'Only translate into {target_lang}.',
      extra_instructions = 'Be terse.',
    })
    eq(s, 'Only translate into Chinese.\n\nBe terse.')
  end)

  -- §4.4: no validation of custom templates.
  it('uses a custom template without {target_lang} verbatim and does not error', function()
    local s = prompt.render({ target_lang = 'Chinese', system_prompt = 'Translate to Klingon.' })
    eq(s, 'Translate to Klingon.')
  end)
end)

describe('prompt.fingerprint', function()
  it('changes when extra_instructions change', function()
    local a = prompt.fingerprint(prompt.render({ target_lang = 'Chinese' }))
    local b = prompt.fingerprint(prompt.render({ target_lang = 'Chinese', extra_instructions = 'x' }))
    neq(a, b)
  end)

  it('is stable for the same rendered string', function()
    local s = prompt.render({ target_lang = 'Chinese' })
    eq(prompt.fingerprint(s), prompt.fingerprint(s))
  end)

  it('is short enough to sit inside a cache key', function()
    eq(#prompt.fingerprint('anything') <= 32, true)
  end)

  -- extra_instructions is arbitrary user configuration, so the rendered prompt
  -- is not guaranteed to be text. See translate.hash for why that matters.
  it('fingerprints a rendered prompt that carries a NUL', function()
    eq(prompt.fingerprint('a\0b'):match('^%x+$') ~= nil, true)
  end)
end)

describe('prompt.user_message', function()
  it('wraps the paragraph in <source_text> byte-for-byte', function()
    local raw = '  Hello\t world  \n\n  second line  '
    eq(prompt.user_message(raw), '<source_text>\n' .. raw .. '\n</source_text>')
  end)
end)

describe('prompt.fences (§4.5)', function()
  local function fenced(body)
    return '前言\n\n```lua\n' .. body .. '\n```\n\n后记'
  end

  it('extracts fenced block contents', function()
    eq(prompt.fences(fenced('local x = 1')), { 'local x = 1' })
  end)

  it('extracts tilde fences too', function()
    eq(prompt.fences('~~~\nabc\n~~~'), { 'abc' })
  end)

  it('reports a match when both sides carry identical code', function()
    eq(prompt.fences_match(fenced('local x = 1'), fenced('local x = 1')), true)
  end)

  it('reports a mismatch when the model rewrote the code', function()
    eq(prompt.fences_match(fenced('local x = 1'), fenced('局部 x = 1')), false)
  end)

  it('reports a mismatch when the model dropped a block entirely', function()
    eq(prompt.fences_match(fenced('local x = 1'), '前言\n\n后记'), false)
  end)

  it('treats prose without fences as matching', function()
    eq(prompt.fences_match('hello', '你好'), true)
  end)

  it('ignores the info string, comparing only contents', function()
    eq(prompt.fences_match('```lua\nx\n```', '```\nx\n```'), true)
  end)
end)
