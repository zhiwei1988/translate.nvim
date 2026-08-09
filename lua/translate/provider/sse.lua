--- Server-sent events framing. Transport only: it knows nothing about the shape
--- of the JSON it hands back.
---
--- curl delivers arbitrary byte boundaries, so a payload routinely arrives split
--- across feeds — buffering incomplete lines is the parser's whole job.
local M = {}

local Parser = {}
Parser.__index = Parser

function M.new()
  return setmetatable({ buffer = '' }, Parser)
end

--- @param chunk string raw bytes from the transport
--- @return string[] payloads complete `data:` values, in order
function Parser:feed(chunk)
  self.buffer = self.buffer .. chunk

  local payloads = {}
  while true do
    local nl = self.buffer:find('\n', 1, true)
    if nl == nil then
      break
    end

    local line = self.buffer:sub(1, nl - 1):gsub('\r$', '')
    self.buffer = self.buffer:sub(nl + 1)

    local data = line:match('^data:%s?(.*)$')
    if data ~= nil then
      payloads[#payloads + 1] = data
    end
  end

  return payloads
end

return M
