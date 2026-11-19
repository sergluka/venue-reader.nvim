local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local equal = MiniTest.expect.equality
local Transport = require("tests.support.transport")

local function start(options)
  local transport = Transport.new()
  local buffer = Lsp.buffer()
  local client = Lsp.start(
    vim.tbl_extend("force", {
      name = "controlled-test-server",
      cmd = transport.command,
      root_dir = vim.uv.cwd(),
      flags = { debounce_text_changes = 10000 },
    }, options or {}),
    buffer
  )
  return transport, client, buffer
end

local function hover_params(buffer)
  return {
    textDocument = { uri = vim.uri_from_bufnr(buffer) },
    position = { line = 0, character = 10 },
  }
end

local tests = MiniTest.new_set()

tests["held requests complete in explicitly selected order"] = function()
  local transport, client, buffer = start()
  assert(not client.initialized)
  transport:initialize()
  Lsp.ready(client, buffer)
  assert(transport:notification("textDocument/didOpen"))
  local received = {}

  local function callback(response_error, result)
    assert(not response_error)
    table.insert(received, result.contents)
  end
  local accepted_first, first_id =
    client:request("textDocument/hover", hover_params(buffer), callback, buffer)
  local accepted_second, second_id =
    client:request("textDocument/hover", hover_params(buffer), callback, buffer)
  assert(accepted_first and accepted_second)
  equal({}, received)
  transport:reply(second_id, { contents = "second" })
  Lsp.wait(function()
    return #received == 1
  end, "second request released first")
  equal({ "second" }, received)
  assert(transport.pending[first_id])
  transport:reply(first_id, { contents = "first" })
  Lsp.wait(function()
    return #received == 2
  end, "first request released second")
  equal({ "second", "first" }, received)
end

tests["cancellation reaches transport and permits a late response"] = function()
  local transport, client, buffer = start()
  transport:initialize()
  Lsp.ready(client, buffer)
  local response
  local accepted, request_id = client:request(
    "textDocument/hover",
    hover_params(buffer),
    function(response_error, result)
      assert(not response_error)
      response = result
    end,
    buffer
  )
  assert(accepted)
  assert(client:cancel_request(request_id))
  equal({ id = request_id }, transport:notification("$/cancelRequest"))
  assert(response == nil)
  transport:reply(request_id, { contents = "late reply" })
  Lsp.wait(function()
    return response ~= nil
  end, "late response after cancellation")
  equal("late reply", response.contents)
end

tests["pending edits are sent before the next document request"] = function()
  local transport, client, buffer = start()
  transport:initialize()
  Lsp.ready(client, buffer)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "8=FIX.4.4|35=1|" })
  assert(not transport:notification("textDocument/didChange"))
  assert(client:request("textDocument/hover", hover_params(buffer), function() end, buffer))
  equal(
    { "textDocument/didChange", "textDocument/hover" },
    { transport.events[#transport.events - 1], transport.events[#transport.events] }
  )
  local change = assert(transport:notification("textDocument/didChange"))
  local eol = vim.bo[buffer].fileformat == "dos" and "\r\n" or "\n"
  equal("8=FIX.4.4|35=1|" .. eol, change.contentChanges[1].text)
end

tests["startup failure exits before initialization"] = function()
  local exit_event
  local transport, client = start({
    on_exit = function(code, signal)
      exit_event = { code, signal }
    end,
  })
  transport:exit(7, 0)
  Lsp.wait(function()
    return exit_event ~= nil
  end, "failed-start exit callback")
  equal({ 7, 0 }, exit_event)
  assert(not client.initialized)
  assert(not transport:notification("initialized"))
end

tests["server exit removes the attached client"] = function()
  local exit_event
  local transport, client, buffer = start({
    on_exit = function(code, signal)
      exit_event = { code, signal }
    end,
  })
  transport:initialize()
  Lsp.ready(client, buffer)
  transport:exit(0, 0)
  Lsp.wait(function()
    return exit_event ~= nil and vim.lsp.get_client_by_id(client.id) == nil
  end, "client removed after exit")
  equal({ 0, 0 }, exit_event)
  assert(not vim.lsp.buf_is_attached(buffer, client.id))
end

return tests
