local M = {}
local reports = {}
local namespace = vim.api.nvim_create_namespace("venue-reader.summary")

function M.wait(predicate, description)
  assert(vim.wait(5000, predicate, 10), description)
end

function M.setup(root, binary, parser)
  if parser then
    vim.opt.runtimepath:prepend(root .. "/.test-deps/treesitter/runtime")
  end
  vim.api.nvim_set_option_value("clipboard", "", {})
  local original = vim.lsp.handlers["textDocument/publishDiagnostics"]
  rawset(vim.lsp.handlers, "textDocument/publishDiagnostics", function(err, result, context, value)
    if not err and result then
      reports[context.client_id .. ":" .. result.uri] = true
    end
    return original(err, result, context, value)
  end)
  require("venue-reader").setup({
    server = { cmd = { binary, "--stdio" } },
    treesitter = { enabled = parser, auto_install = false },
    summary = { mode = "front" },
  })
end

function M.buffer(lines, name)
  local buffer = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buffer)
  if name then
    vim.api.nvim_buf_set_name(buffer, name)
  end
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.api.nvim_set_option_value("filetype", "fix", { buf = buffer })
  return buffer
end

function M.ready(buffer)
  local client
  M.wait(function()
    client = vim.lsp.get_clients({ bufnr = buffer, name = "venue-reader" })[1]
    return client and reports[client.id .. ":" .. vim.uri_from_bufnr(buffer)]
  end, "committed FIX document")
  return client
end

function M.marks(buffer)
  vim.cmd("redraw!")
  return vim.api.nvim_buf_get_extmarks(buffer, namespace, 0, -1, { details = true })
end

function M.mode(buffer, mode)
  require("venue-reader").summary(mode)
  M.wait(function()
    local status = require("venue-reader").status(buffer).annotations
    if status.problem then
      return false
    end
    if mode == "front" or mode == "above" then
      return #M.marks(buffer) == 1
    end
    if mode == "codelens" then
      return #vim.lsp.codelens.get({ bufnr = buffer }) > 0 and #M.marks(buffer) == 0
    end
    return #M.marks(buffer) == 0
  end, "render mode " .. mode)
end

return M
