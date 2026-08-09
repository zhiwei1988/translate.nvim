--- SHA-256 over material that is not guaranteed to be text.
---
--- A Lua string carrying a NUL byte crosses into Vimscript as a Blob rather
--- than a String, and sha256() rejects a Blob with E976 on Neovim 0.10 — the
--- oldest version this plugin supports. Both callers can hit that: the cache
--- key joins its fields with NUL separators, and a rendered prompt carries
--- whatever extra_instructions the user configured.
---
--- Hex encoding is injective, so hashing the encoding hashes the same identity.
local M = {}

--- @param material string
--- @return string hex digest
function M.digest(material)
  return vim.fn.sha256(vim.text.hexencode(material))
end

return M
