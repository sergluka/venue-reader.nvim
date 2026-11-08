local directory = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local release = vim.json.decode(table.concat(vim.fn.readfile(directory .. "/release.json"), "\n"))

local version_series = release.version:match("^(%d+%.%d+)%.%d+$")
assert(version_series, "Expected a stable server version")
assert(type(release.series) == "string", "Expected a compatible server series")
release.pinned = version_series == release.series
release.base_url = ("https://github.com/%s/releases/download/v%s/"):format(
  release.repository,
  release.version
)

return release
