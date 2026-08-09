--- The single Adapter (CONTEXT.md: Adapter) — OpenAI-compatible SSE.
---
--- Deliberately thin: build a request, emit text deltas, be killable. Caching,
--- the grace period, the in-flight table, the concurrency gate, retries and
--- prompt rendering all live in the 翻译调度层 and are invisible from here. The
--- thinner this extension point is, the likelier a third party actually writes
--- their own (spec §2).
local M = {}

local sse = require('translate.provider.sse')

local uv = vim.uv or vim.loop

--- Cap on how much of a non-stream response we keep for the error message.
local ERROR_BODY_LIMIT = 4096

local function join_url(base_url, path)
  return (base_url:gsub('/+$', '')) .. '/' .. (path:gsub('^/+', ''))
end

--- @return string class one of auth/quota/rate_limit/bad_request/server/network
local function classify(status)
  if status == 401 or status == 403 then
    return 'auth'
  elseif status == 402 then
    return 'quota'
  elseif status == 429 then
    return 'rate_limit'
  elseif status == 400 or status == 422 or (status >= 404 and status < 500) then
    return 'bad_request'
  elseif status >= 500 then
    return 'server'
  end
  return 'network'
end

--- Try the documented `{"error": {...}}` envelope first, but never let a parse
--- failure swallow what the server said (spec §5.5).
local function error_message(body)
  local text = vim.trim(body or '')
  if text == '' then
    return '(empty response body)'
  end

  local ok, decoded = pcall(vim.json.decode, text)
  if ok and type(decoded) == 'table' then
    local err = decoded.error
    if type(err) == 'table' and type(err.message) == 'string' then
      return err.message
    end
    if type(err) == 'string' then
      return err
    end
    if type(decoded.message) == 'string' then
      return decoded.message
    end
  end

  return text:sub(1, ERROR_BODY_LIMIT)
end

local function hint_for(class, preset)
  if class == 'auth' then
    return ('API key 无效或未设置。请检查环境变量 %s，或在 setup() 里显式传入 api_key。'):format(
      preset.api_key_env or '(未声明)'
    )
  elseif class == 'quota' then
    return ('余额或配额已耗尽。请前往 %s 充值或提额。'):format(preset.billing_url or '服务商控制台')
  end
  return nil
end

--- Extract the text delta from one SSE payload.
---
--- `reasoning_content` is dropped on purpose — there is no on_reasoning channel
--- and it must never be spliced into the user's document. But it is dropped
--- *independently* of `content`: a thinking model routinely emits a frame
--- carrying both, or an empty reasoning field beside real text, and treating
--- the frame as reasoning would silently swallow the translation.
local function delta_text(payload)
  local ok, frame = pcall(vim.json.decode, payload)
  if not ok or type(frame) ~= 'table' then
    return nil
  end

  local choice = (frame.choices or {})[1]
  if type(choice) ~= 'table' or type(choice.delta) ~= 'table' then
    return nil
  end

  local content = choice.delta.content
  if type(content) == 'string' and content ~= '' then
    return content
  end
  return nil
end

local function build_body(req, preset)
  local body = vim.tbl_extend('force', {}, preset.extra_body or {})

  body.model = req.model
  body.messages = {
    { role = 'system', content = req.system },
    { role = 'user', content = req.text },
  }
  body.stream = true
  body.temperature = req.temperature

  -- No max_tokens, ever. The only thing a ceiling buys is a *truncated*
  -- translation, which is worse than a slow one (spec §5.4).
  body.max_tokens = nil

  local thinking = preset.thinking or {}
  for k, v in pairs((req.thinking and thinking.on or thinking.off) or {}) do
    body[k] = v
  end

  for _, param in ipairs(preset.drop_params or {}) do
    body[param] = nil
  end

  return body
end

--- Write the credential to a 0600 file curl reads with `--config`, so it never
--- appears in argv where any local `ps` can read it.
---
--- Lives under `tempname()`, i.e. inside the 0700 per-process directory nvim
--- already creates and cleans up, rather than a shared runtime dir that may not
--- even be writable.
--- @return string|nil path, string|nil err — both nil means "no credential to send"
local function write_auth_config(api_key)
  if api_key == nil or api_key == '' then
    return nil, nil
  end

  local path = vim.fn.tempname() .. '-translate-auth'
  local fd = uv.fs_open(path, 'w', 384)
  if fd == nil then
    -- Never fall through and send the request without the header: it would come
    -- back as a 401 and send the user hunting for a key that was never missing.
    return nil, ('无法写入临时凭据文件：%s'):format(path)
  end

  local escaped = api_key:gsub('\\', '\\\\'):gsub('"', '\\"')
  uv.fs_write(fd, ('header = "Authorization: Bearer %s"\n'):format(escaped), 0)
  uv.fs_close(fd)
  return path, nil
end

--- @param opts table { preset, api_key, curl }
--- @return table provider with `translate(req, handlers) -> handle`
function M.new(opts)
  local preset = opts.preset
  local url = join_url(preset.base_url, preset.path or '/chat/completions')

  local provider = { name = preset.name, preset = preset }

  --- @param req table { text, system, model, temperature, thinking } — `text`
  --- is the user-message content, already rendered upstream; the adapter does
  --- no prompt work of its own.
  function provider.translate(req, handlers)
    local parser = sse.new()
    local state = { aborted = false, settled = false, saw_delta = false, head = {}, head_len = 0 }

    local auth_config, auth_err = write_auth_config(opts.api_key)
    if auth_err ~= nil then
      vim.schedule(function()
        handlers.on_error({ class = 'auth', message = auth_err })
      end)
      return { abort = function() end }
    end

    local function cleanup()
      if auth_config ~= nil then
        uv.fs_unlink(auth_config)
        auth_config = nil
      end
    end

    local function settle(fn)
      if state.settled or state.aborted then
        return
      end
      state.settled = true
      cleanup()
      vim.schedule(fn)
    end

    local cmd = { opts.curl or 'curl', '-sS', '-N', '--no-buffer' }
    if auth_config ~= nil then
      vim.list_extend(cmd, { '--config', auth_config })
    end
    vim.list_extend(cmd, {
      '-X',
      'POST',
      url,
      '-H',
      'Content-Type: application/json',
      '-H',
      'Accept: text/event-stream',
      -- %{stderr} keeps the status code off stdout, so the SSE stream stays
      -- clean. The label makes the parse immune to curl's own diagnostics,
      -- which share stderr and can themselves end in digits.
      '-w',
      '%{stderr}\ntranslate-http-status:%{http_code}\n',
      '--data-binary',
      '@-',
    })

    local stderr_parts = {}

    local proc = vim.system(cmd, {
      stdin = vim.json.encode(build_body(req, preset)),
      text = true,
      stderr = function(_, data)
        if data ~= nil then
          stderr_parts[#stderr_parts + 1] = data
        end
      end,
      stdout = function(_, data)
        if data == nil or state.aborted then
          return
        end

        -- Kept only until we know this is a real stream; on an error status
        -- this is the body we have to show the user.
        if not state.saw_delta and state.head_len < ERROR_BODY_LIMIT then
          state.head[#state.head + 1] = data
          state.head_len = state.head_len + #data
        end

        for _, payload in ipairs(parser:feed(data)) do
          if payload ~= '[DONE]' then
            local text = delta_text(payload)
            if text ~= nil then
              state.saw_delta = true
              vim.schedule(function()
                if not state.aborted then
                  handlers.on_chunk(text)
                end
              end)
            end
          end
        end
      end,
    }, function(result)
      if state.aborted then
        cleanup()
        return
      end

      local stderr = table.concat(stderr_parts)
      local status = tonumber(stderr:match('translate%-http%-status:(%d+)') or '') or 0

      if status == 200 then
        -- The headers said 200, but a non-zero exit means the body was cut off
        -- part-way. Reporting completion here would hand the scheduler a
        -- truncated translation, which it would then cache forever (§6.5).
        if result.code ~= 0 then
          return settle(function()
            handlers.on_error({
              class = 'network',
              status = status,
              message = ('响应在传输中断开（curl 退出码 %d），译文不完整'):format(result.code),
            })
          end)
        end
        if state.saw_delta then
          return settle(handlers.on_done)
        end
        -- 200 with nothing resembling a stream: a proxy or a gateway spoke
        -- instead of the model.
        return settle(function()
          handlers.on_error({
            class = 'server',
            status = status,
            message = error_message(table.concat(state.head)),
          })
        end)
      end

      local class = status == 0 and 'network' or classify(status)
      local message
      if class == 'network' then
        message = vim.trim((stderr:gsub('%d%d%d%s*$', '')))
        if message == '' then
          message = ('curl 退出码 %d'):format(result.code)
        end
      else
        message = error_message(table.concat(state.head))
      end

      settle(function()
        handlers.on_error({
          class = class,
          status = status ~= 0 and status or nil,
          message = message,
          hint = hint_for(class, preset),
        })
      end)
    end)

    return {
      --- Immediate. The grace period and in-flight reuse are the scheduler's
      --- business; this provider knows nothing about them.
      abort = function()
        if state.aborted or state.settled then
          return
        end
        state.aborted = true
        cleanup()
        pcall(function()
          proc:kill('sigterm')
        end)
      end,
    }
  end

  return provider
end

M._classify = classify
M._error_message = error_message
M._join_url = join_url

return M
