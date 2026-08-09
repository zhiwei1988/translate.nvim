local eq = MiniTest.expect.equality
local neq = MiniTest.expect.no_equality
local cache = require('translate.cache')

local function key(over)
  return cache.key(vim.tbl_extend('force', {
    text = 'Hello world.',
    block_type = 'paragraph',
    target_lang = 'Chinese',
    provider = 'deepseek',
    model = 'deepseek-v4-flash',
    prompt_fp = 'abc123',
  }, over or {}))
end

describe('cache.normalize', function()
  it('trims each line, joins with a single space and collapses whitespace runs', function()
    eq(cache.normalize('  a  b \n\t c  \n'), 'a b c')
  end)
end)

describe('cache.key — prose is normalized (§6.1)', function()
  it('hits the same key when prose is re-wrapped', function()
    local a = key({ text = 'The quick brown fox\njumps over the lazy dog.' })
    local b = key({ text = 'The quick brown fox jumps\nover the lazy dog.' })
    eq(a, b)
  end)

  it('hits the same key when prose is re-indented', function()
    eq(key({ text = 'one\n  two' }), key({ text = '  one\ntwo  ' }))
  end)
end)

describe('cache.key — structured blocks keep raw bytes (§6.1)', function()
  -- Normalizing would fold "- a\n- b" into "- a - b" and collide with a
  -- single-item list that means something else entirely.
  it('separates a two-item list from a one-item list with the same words', function()
    local two = key({ text = '- a\n- b', block_type = 'list' })
    local one = key({ text = '- a - b', block_type = 'list' })
    neq(two, one)
  end)

  it('keeps table row structure significant', function()
    neq(key({ text = '| a |\n| b |', block_type = 'table' }), key({ text = '| a | | b |', block_type = 'table' }))
  end)

  it('keeps quote line structure significant', function()
    neq(key({ text = '> a\n> b', block_type = 'quote' }), key({ text = '> a > b', block_type = 'quote' }))
  end)

  it('keeps a visual selection on raw bytes', function()
    neq(key({ text = 'a\nb', block_type = 'selection' }), key({ text = 'a b', block_type = 'selection' }))
  end)

  it('gives a list and a paragraph with identical bytes different keys', function()
    neq(key({ text = '- a', block_type = 'list' }), key({ text = '- a', block_type = 'paragraph' }))
  end)
end)

describe('cache.key — configuration components', function()
  it('changes with the prompt fingerprint', function()
    neq(key(), key({ prompt_fp = 'deadbeef' }))
  end)

  it('changes with the target language', function()
    neq(key(), key({ target_lang = 'Japanese' }))
  end)

  it('changes with provider and model', function()
    neq(key(), key({ provider = 'gemini' }))
    neq(key(), key({ model = 'other' }))
  end)

  -- temperature / max_tokens / thinking are deliberately absent: they do not
  -- change what the paragraph *means*, and putting them in would blow the whole
  -- cache away the first time someone nudges the temperature (§6.1).
  it('ignores sampling parameters entirely', function()
    local sampled = cache.key({
      text = 'Hello world.',
      block_type = 'paragraph',
      target_lang = 'Chinese',
      provider = 'deepseek',
      model = 'deepseek-v4-flash',
      prompt_fp = 'abc123',
      temperature = 0.9,
      thinking = true,
      max_tokens = 4096,
    })
    eq(sampled, key())
  end)

  it('cannot be spoofed by moving a separator into a field', function()
    neq(
      key({ text = 'a', target_lang = 'b\0c' }),
      key({ text = 'a\0b', target_lang = 'c' })
    )
  end)
end)

describe('cache.key — shape', function()
  it('is a hex digest whose first two chars can shard a directory', function()
    eq(key():match('^%x+$') ~= nil, true)
    eq(#key() >= 32, true)
  end)
end)

-- A Lua string carrying a NUL crosses into Vimscript as a Blob rather than a
-- String, and sha256() on Neovim 0.10 — the oldest version this plugin claims
-- to support — rejects a Blob with E976. Any field can carry one, so the key
-- material is hex-encoded on its way to the digest.
describe('cache.key — a NUL byte in any field', function()
  it('still keys a paragraph whose text carries one', function()
    eq(key({ text = 'a\0b' }):match('^%x+$') ~= nil, true)
  end)

  it('still keys a configuration component that carries one', function()
    eq(key({ model = 'a\0b' }):match('^%x+$') ~= nil, true)
  end)
end)
