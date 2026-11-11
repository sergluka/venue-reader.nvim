local M = {}
local routers = {}
local sequence = 0

local function release(request)
  if request.timer then
    request.timer:stop()
    request.timer:close()
    request.timer = nil
  end
  local routing = request.routing
  if not routing then
    return
  end
  routing.tokens[request.partial_token] = nil
  routing.tokens[request.work_token] = nil
  if next(routing.tokens) == nil then
    if request.client.handlers["$/progress"] == routing.handler then
      request.client.handlers["$/progress"] = routing.previous
    end
    if routers[request.client.id] == routing then
      routers[request.client.id] = nil
    end
  end
  request.routing = nil
end

local function router(client)
  local routing = routers[client.id]
  if routing and client.handlers["$/progress"] == routing.handler then
    return routing
  end
  routing = { tokens = {}, previous = client.handlers["$/progress"] }
  routing.handler = function(err, params, context, config)
    local callback = type(params) == "table" and routing.tokens[params.token]
    if callback then
      callback(err, params.value)
    else
      local previous = routing.previous or vim.lsp.handlers["$/progress"]
      if previous then
        return previous(err, params, context, config)
      end
    end
  end
  client.handlers["$/progress"] = routing.handler
  routers[client.id] = routing
  return routing
end

function M.start(client, buffer, options)
  sequence = sequence + 1
  local prefix = "venue-reader-symbols:" .. client.id .. ":" .. sequence
  local request = {
    client = client,
    partial_token = prefix .. ":result",
    work_token = prefix .. ":work",
    done = false,
    streamed = false,
  }
  local last_event = vim.uv.hrtime()

  function request.cancel()
    if request.done then
      return
    end
    request.done = true
    release(request)
    if request.id then
      client:cancel_request(request.id)
      request.id = nil
    end
  end

  local function finish(err)
    if request.done then
      return
    end
    request.done = true
    request.id = nil
    release(request)
    options.on_done(err)
  end

  local function fail(message)
    local request_id = request.id
    finish({ message = tostring(message) })
    if request_id then
      client:cancel_request(request_id)
    end
  end

  local function deliver(symbols)
    if type(symbols) ~= "table" or not vim.islist(symbols) then
      fail("Invalid document symbol result: expected an array")
      return false
    end
    local success, failure = pcall(options.on_batch, symbols)
    if not success then
      fail(failure)
    end
    return success
  end

  request.routing = router(client)
  request.routing.tokens[request.partial_token] = function(err, symbols)
    if request.done then
      return
    end
    last_event = vim.uv.hrtime()
    if err then
      finish(err)
    else
      request.streamed = true
      deliver(symbols)
    end
  end
  request.routing.tokens[request.work_token] = function(err, progress)
    if request.done then
      return
    end
    last_event = vim.uv.hrtime()
    if err then
      finish(err)
    elseif type(progress) == "table" then
      options.on_progress(progress)
    end
  end
  request.timer = assert(vim.uv.new_timer())
  request.timer:start(
    100,
    100,
    vim.schedule_wrap(function()
      if request.done then
        return
      end
      if client:is_stopped() or not vim.lsp.buf_is_attached(buffer, client.id) then
        fail("Venue Reader disconnected")
      elseif client.handlers["$/progress"] ~= request.routing.handler then
        fail("LSP progress handler was replaced")
      elseif
        options.timeout_ms > 0 and (vim.uv.hrtime() - last_event) / 1e6 >= options.timeout_ms
      then
        fail("Document symbols timed out")
      end
    end)
  )

  local success, accepted, request_id = pcall(
    client.request,
    client,
    "textDocument/documentSymbol",
    {
      textDocument = { uri = vim.uri_from_bufnr(buffer) },
      partialResultToken = request.partial_token,
      workDoneToken = request.work_token,
    },
    function(err, result)
      if request.done then
        return
      end
      request.id = nil
      if err then
        finish(err)
        return
      end
      if result ~= nil and result ~= vim.NIL then
        if type(result) ~= "table" or not vim.islist(result) then
          fail("Invalid document symbol response: expected an array")
          return
        end
        if request.streamed and #result > 0 then
          fail("Server returned a populated final result after partial symbols")
          return
        end
        if not request.streamed and not deliver(result) then
          return
        end
      end
      finish(nil)
    end,
    buffer
  )
  if not success or not accepted then
    fail(success and "Document symbol request was rejected" or accepted)
  elseif not request.done then
    request.id = request_id
  end
  return request
end

return M
