local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local Symbols = {}

function Symbols.symbol(name, line, kind)
  local range = {
    start = { line = line or 0, character = 0 },
    ["end"] = { line = line or 0, character = 1 },
  }
  return { name = name, kind = kind or 12, range = range, selectionRange = range }
end

function Symbols.status(picker)
  if not vim.api.nvim_buf_is_valid(picker.prompt_bufnr) then
    return ""
  end
  local messages = {}
  for _, marker in
    ipairs(vim.api.nvim_buf_get_extmarks(picker.prompt_bufnr, -1, 0, -1, { details = true }))
  do
    for _, text in ipairs(marker[4].virt_text or {}) do
      messages[#messages + 1] = text[1]
    end
  end
  return table.concat(messages, " ")
end

function Symbols.has_status(picker, value)
  return Symbols.status(picker):find(value, 1, true) ~= nil
end

function Symbols.results(picker)
  return picker.manager and picker.manager:num_results() or 0
end

function Symbols.query(picker, query, expected)
  local scans = 0
  picker:register_completion_callback(function()
    scans = scans + 1
  end)
  picker:set_prompt(query, true)
  Lsp.wait(function()
    return scans > 0 and Symbols.results(picker) == expected
  end, "query " .. query)
end

function Symbols.close(picker)
  if vim.api.nvim_buf_is_valid(picker.prompt_bufnr) then
    -- Headless Lua waits do not consume Telescope's queued insert-mode keys.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    require("telescope.actions").close(picker.prompt_bufnr)
  end
end

function Symbols.fixture(options)
  options = options or {}
  local pickers = {}
  -- mini.test runs finalizers in registration order; close floats before source buffers.
  MiniTest.finally(function()
    for _, picker in ipairs(pickers) do
      Symbols.close(picker)
    end
    vim.cmd("stopinsert")
  end)
  local buffer = Lsp.buffer({ "first", "second", "third", "fourth" })
  vim.api.nvim_set_current_buf(buffer)
  local progress = {}
  local custom_handler = function(_, params)
    progress[#progress + 1] = params
  end
  local client = Lsp.start({
    name = "symbol-test",
    cmd = {
      "python3",
      assert(vim.env.VENUE_READER_TEST_ROOT) .. "/tests/support/symbol_server.py",
    },
    root_dir = vim.uv.cwd(),
    handlers = { ["$/progress"] = custom_handler },
  }, buffer)
  Lsp.ready(client, buffer)
  local fixture = {
    client = client,
    buffer = buffer,
    progress = progress,
    original_handler = custom_handler,
  }
  function fixture:control(method, params)
    local source = vim.api.nvim_buf_is_valid(self.buffer) and self.buffer or nil
    return Lsp.request(self.client, "test/" .. method, params or {}, source)
  end
  function fixture:state()
    return self:control("state")
  end
  function fixture:open(overrides)
    vim.api.nvim_set_current_buf(buffer)
    local count = #self:state().requests
    local picker = require("venue-reader.symbols").open(
      client,
      buffer,
      vim.tbl_extend("force", {
        previewer = false,
        timeout_ms = 5000,
        sorting_strategy = "ascending",
      }, options, overrides or {})
    )
    assert(picker, "picker opened")
    pickers[#pickers + 1] = picker
    local request
    Lsp.wait(function()
      request = self:state().requests[count + 1]
      return request ~= nil
    end, "document symbol request")
    return picker, request
  end
  function fixture:chunk(request, values, picker, count)
    self:control("chunk", { request = request.id, symbols = values })
    if picker then
      Lsp.wait(function()
        return Symbols.results(picker) == count and (count == 0 or picker:get_selection() ~= nil)
      end, "incremental symbol results")
    end
  end
  function fixture:cancelled(request)
    return vim.list_contains(self:state().cancelled, request.id)
  end
  return fixture
end

return Symbols
