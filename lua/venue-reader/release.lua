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

function release.platform()
  local system = vim.uv.os_uname()
  local architecture = ({ arm64 = "aarch64", AMD64 = "x86_64" })[system.machine] or system.machine
  local suffix = ({
    Linux = "unknown-linux-gnu",
    Darwin = "apple-darwin",
    Windows_NT = "pc-windows-msvc",
  })[system.sysname]
  local target = architecture .. "-" .. (suffix or "unsupported")
  return target, system.sysname
end

return release
