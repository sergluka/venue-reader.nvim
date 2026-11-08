local M = {}

local types = {
  F = "property",
  E = "enumMember",
  N = "number",
  P = "price",
  Q = "quantity",
  M = "money",
  S = "string",
  K = "keyword",
  U = "namespace",
  C = "comment",
  T = "timestamp",
  G = "group",
  B = "flag",
}
local combinations, status_groups = {}, {}
local base_groups = { "VenueReaderSummary" }

local function defined(name)
  return next(vim.api.nvim_get_hl(0, { name = name, link = false, create = false })) ~= nil
end

local function add_group(groups, name)
  if defined(name .. ".fix") then
    groups[#groups + 1] = name .. ".fix"
  elseif defined(name) then
    groups[#groups + 1] = name
  end
end

local function highlight(token, client, semantic)
  if
    not semantic
    or type(token) ~= "table"
    or not types[token[1]]
    or type(token[2]) ~= "number"
    or token[2] < 0
    or token[2] % 1 ~= 0
    or token[2] > 2147483647
  then
    return base_groups
  end
  local letter, mask = token[1], token[2]
  -- A client's legend does not change while it lives, so the client id identifies it.
  local owner = client and client.id or false
  local by_type = combinations[owner]
  if not by_type then
    by_type = {}
    combinations[owner] = by_type
  end
  local by_mask = by_type[letter]
  if not by_mask then
    by_mask = {}
    by_type[letter] = by_mask
  end
  local cached = by_mask[mask]
  if cached then
    return cached
  end
  local legend = client and client.server_capabilities.semanticTokensProvider
  local modifiers = legend and legend.legend and legend.legend.tokenModifiers or {}
  local groups = base_groups
  if #modifiers >= 31 or mask < 2 ^ #modifiers then
    groups = { "VenueReaderSummary" }
    local kind = types[letter]
    add_group(groups, "@lsp.type." .. kind)
    for index, modifier in ipairs(modifiers) do
      if bit.band(mask, bit.lshift(1, index - 1)) ~= 0 then
        add_group(groups, "@lsp.mod." .. modifier)
      end
    end
    for index, modifier in ipairs(modifiers) do
      if bit.band(mask, bit.lshift(1, index - 1)) ~= 0 then
        add_group(groups, "@lsp.typemod." .. kind .. "." .. modifier)
      end
    end
  end
  by_mask[mask] = groups
  return groups
end

function M.chunks(hint, client, semantic, padding)
  local chunks = {}
  if padding and hint.paddingLeft then
    chunks[#chunks + 1] = { " ", base_groups }
  end
  if type(hint.label) == "string" then
    chunks[#chunks + 1] = { hint.label, base_groups }
  elseif type(hint.label) == "table" then
    local tokens = type(hint.data) == "table" and hint.data.tokens
    for index, part in ipairs(hint.label) do
      if type(part) == "table" and type(part.value) == "string" then
        local token = type(tokens) == "table" and tokens[index] or nil
        chunks[#chunks + 1] = { part.value, highlight(token, client, semantic) }
      end
    end
  end
  if padding and hint.paddingRight then
    chunks[#chunks + 1] = { " ", base_groups }
  end
  return chunks
end

function M.statusline(chunks)
  local output = {}
  for _, chunk in ipairs(chunks) do
    -- Group lists are shared, long-lived tables, so their identity is the key.
    local key = chunk[2]
    local name = status_groups[key]
    if not name then
      local style = {}
      for _, group in ipairs(chunk[2]) do
        style =
          vim.tbl_extend("force", style, vim.api.nvim_get_hl(0, { name = group, link = false }))
      end
      name = "VenueReaderSummaryStatus" .. vim.tbl_count(status_groups)
      vim.api.nvim_set_hl(0, name, style)
      status_groups[key] = name
    end
    output[#output + 1] = "%#" .. name .. "#" .. chunk[1]:gsub("%%", "%%%%")
  end
  output[#output + 1] = "%*"
  return table.concat(output)
end

function M.clear()
  combinations, status_groups = {}, {}
end

return M
