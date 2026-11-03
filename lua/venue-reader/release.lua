local directory = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local release = vim.json.decode(table.concat(vim.fn.readfile(directory .. "/release.json"), "\n"))

release.series =
  assert(release.version:match("^(%d+%.%d+)%.%d+$"), "Expected a stable server version")
release.base_url = ("https://github.com/%s/releases/download/v%s/"):format(
  release.repository,
  release.version
)

return release
