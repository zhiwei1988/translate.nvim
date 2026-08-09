local eq = MiniTest.expect.equality
local sse = require('translate.provider.sse')

local function collect(chunks)
  local parser, out = sse.new(), {}
  for _, chunk in ipairs(chunks) do
    vim.list_extend(out, parser:feed(chunk))
  end
  return out
end

describe('sse framing', function()
  it('yields one payload per data line', function()
    eq(collect({ 'data: a\n\ndata: b\n\n' }), { 'a', 'b' })
  end)

  -- The whole point of the parser: curl hands us arbitrary byte boundaries.
  it('reassembles a payload split across feeds', function()
    eq(collect({ 'data: hel', 'lo\n\n' }), { 'hello' })
  end)

  it('reassembles a payload split mid-prefix', function()
    eq(collect({ 'da', 'ta', ': hello\n\n' }), { 'hello' })
  end)

  it('holds an unterminated line back until its newline arrives', function()
    local parser = sse.new()
    eq(parser:feed('data: partial'), {})
    eq(parser:feed('\n'), { 'partial' })
  end)

  it('accepts CRLF line endings', function()
    eq(collect({ 'data: a\r\n\r\ndata: b\r\n\r\n' }), { 'a', 'b' })
  end)

  it('accepts a data line with no space after the colon', function()
    eq(collect({ 'data:a\n\n' }), { 'a' })
  end)

  it('ignores comments, blank lines and non-data fields', function()
    eq(collect({ ': ping\n\nevent: message\nid: 7\ndata: a\n\n' }), { 'a' })
  end)

  it('passes the terminator through as a payload', function()
    eq(collect({ 'data: a\n\ndata: [DONE]\n\n' }), { 'a', '[DONE]' })
  end)

  it('preserves whitespace inside a payload', function()
    eq(collect({ 'data: {"a": "b  c"}\n\n' }), { '{"a": "b  c"}' })
  end)

  it('yields nothing for an empty stream', function()
    eq(collect({ '' }), {})
  end)
end)
