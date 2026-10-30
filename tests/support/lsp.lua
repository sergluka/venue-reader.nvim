local MiniTest = require("mini.test")
local Lsp = {}

function Lsp.wait(predicate, description)
  assert(vim.wait(5000, predicate, 10), "Timed out: " .. description)
end

function Lsp.buffer(lines)
  local buffer = vim.api.nvim_create_buf(true, false)
  MiniTest.finally(function()
    if vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
  end)
  vim.api.nvim_buf_set_name(buffer, vim.fs.joinpath(vim.uv.cwd(), "input-" .. buffer .. ".fix"))
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines or { "8=FIX.4.4|35=0|" })
  vim.api.nvim_set_option_value("filetype", "fix", { buf = buffer })
  return buffer
end

function Lsp.start(config, buffer)
  local client_id = assert(vim.lsp.start(config, {
    bufnr = buffer,
    reuse_client = function()
      return false
    end,
  }))
  MiniTest.finally(function()
    local client = vim.lsp.get_client_by_id(client_id)
    if client then
      client:stop(true)
    end
    Lsp.wait(function()
      return vim.lsp.get_client_by_id(client_id) == nil
    end, "client cleanup")
  end)
  return assert(vim.lsp.get_client_by_id(client_id))
end

function Lsp.ready(client, buffer)
  Lsp.wait(function()
    return client.initialized and vim.lsp.buf_is_attached(buffer, client.id)
  end, "LSP initialization and attachment")
end

function Lsp.request(client, method, params, buffer)
  local response, failure = client:request_sync(method, params, 5000, buffer)
  assert(response, failure)
  assert(not response.err, vim.inspect(response.err))
  return response.result
end

return Lsp
