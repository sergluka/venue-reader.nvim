local M = {}

local types = {
  price = "@number",
  quantity = "@number",
  money = "@number",
  timestamp = "@string",
  flag = "DiagnosticWarn",
}
local groups = {
  group1a = "DiffAdd",
  group1b = "DiffChange",
  group2a = "DiffDelete",
  group2b = "DiffText",
  group3a = "Pmenu",
  group3b = "Folded",
}

local function apply()
  for kind, target in pairs(types) do
    vim.api.nvim_set_hl(0, "@lsp.type." .. kind .. ".fix", { default = true, link = target })
  end
  for modifier, target in pairs({ peer1 = "Identifier", peer2 = "Special" }) do
    vim.api.nvim_set_hl(0, "@lsp.mod." .. modifier .. ".fix", { default = true, link = target })
  end
  for modifier, source in pairs(groups) do
    local style = vim.api.nvim_get_hl(0, { name = source, link = false })
    if style.bg or style.ctermbg then
      vim.api.nvim_set_hl(0, "@lsp.typemod.group." .. modifier .. ".fix", {
        default = true,
        bg = style.bg,
        ctermbg = style.ctermbg,
      })
    end
  end
end

function M.setup()
  apply()
  local group = vim.api.nvim_create_augroup("venue-reader.highlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = apply })
end

return M
