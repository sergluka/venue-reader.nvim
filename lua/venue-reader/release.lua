local directory = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local release = vim.json.decode(table.concat(vim.fn.readfile(directory .. "/release.json"), "\n"))

local function download_base(version)
  return ("https://github.com/%s/releases/download/v%s/"):format(release.repository, version)
end

function release.valid_version(value)
  return type(value) == "string"
    and value:match("^%d+%.%d+%.%d+$") ~= nil
    and ("." .. value):find("%.0%d") == nil
end

release.major = assert(release.series:match("^(%d+)%.%d+$"), "Expected a compatible server series")

function release.compatible(value)
  return release.valid_version(value) and value:match("^%d+") == release.major
end

function release.newer(left, right)
  local right_component = right:gmatch("%d+")
  for component in left:gmatch("%d+") do
    local other = right_component()
    if #component ~= #other then
      return #component > #other
    elseif component ~= other then
      return component > other
    end
  end
  return false
end

assert(release.valid_version(release.version), "Expected a stable server version")
release.pinned = release.compatible(release.version)
release.base_url = download_base(release.version)

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

local function request(endpoint, callback)
  local system = vim.uv.os_uname().sysname
  local command = {
    system == "Windows_NT" and "curl.exe" or "curl",
    "--disable",
    "--silent",
    "--show-error",
    "--write-out",
    "\n%{http_code}",
    "--proto",
    "=https",
    "--connect-timeout",
    "5",
    "--max-time",
    "15",
    "--max-filesize",
    "4194304",
    "--header",
    "Accept: application/vnd.github+json",
    "https://api.github.com/repos/" .. release.repository .. "/releases" .. endpoint,
  }
  local ok, failure = pcall(
    vim.system,
    command,
    { text = true },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        callback(
          ("Cannot read release metadata: curl exited %d: %s"):format(
            result.code,
            vim.trim(result.stderr or "")
          )
        )
        return
      end
      local body, status = (result.stdout or ""):match("^(.*)\n(%d%d%d)$")
      local decoded, data = pcall(vim.json.decode, body or "")
      if status and status ~= "200" then
        callback("GitHub release metadata returned HTTP " .. status)
      elseif not status or not decoded or type(data) ~= "table" then
        callback("Invalid GitHub release metadata")
      else
        callback(nil, data)
      end
    end)
  )
  if not ok then
    callback("Cannot read release metadata: " .. tostring(failure))
  end
end

local function published_version(entry)
  if type(entry) == "table" and entry.draft == false and entry.prerelease == false then
    local tag = entry.tag_name
    local version = type(tag) == "string" and tag:match("^v(.+)$")
    if release.compatible(version) then
      return version
    end
  end
end

local function select_asset(version, entry, target, callback)
  if version == release.version and release.artifacts[target] then
    callback(nil, release)
    return
  end
  local suffix = vim.endswith(target, "-windows-msvc") and ".zip" or ".tar.gz"
  local archive = "venue-reader-" .. target .. suffix
  for _, asset in ipairs(type(entry.assets) == "table" and entry.assets or {}) do
    if type(asset) == "table" and asset.name == archive and asset.state == "uploaded" then
      local digest = type(asset.digest) == "string" and asset.digest:match("^sha256:(%x+)$")
      if not digest or #digest ~= 64 then
        callback("Missing or invalid SHA-256 for " .. archive .. " at v" .. version)
        return
      end
      callback(nil, {
        version = version,
        base_url = download_base(version),
        artifacts = { [target] = { archive = archive, sha256 = digest:lower() } },
      })
      return
    end
  end
  -- A matching external installation can run on a platform without a published archive.
  callback(nil, { version = version, base_url = download_base(version), artifacts = {} })
end

local cached_latest = {}
local pending_latest = {}
local page_size = 20

function release.resolve(selector, target, callback, refresh)
  if selector ~= "latest" then
    if not release.compatible(selector) then
      callback("Unsupported server version: " .. tostring(selector))
    elseif selector == release.version and release.artifacts[target] then
      callback(nil, release)
    else
      request("/tags/v" .. selector, function(error, entry)
        if error or published_version(entry) ~= selector then
          callback(error or "Missing stable release v" .. selector)
          return
        end
        select_asset(selector, entry, target, callback)
      end)
    end
    return
  end
  if pending_latest[target] then
    table.insert(pending_latest[target], callback)
    return
  elseif cached_latest[target] and not refresh then
    callback(nil, cached_latest[target])
    return
  end

  local waiters = { callback }
  pending_latest[target] = waiters
  local function finish(error, selected)
    pending_latest[target] = nil
    if selected then
      cached_latest[target] = selected.artifacts[target] and selected
    end
    for _, waiter in ipairs(waiters) do
      waiter(error, selected)
    end
  end

  local best_version, best_entry
  local function scan(page)
    request(("?per_page=%d&page=%d"):format(page_size, page), function(error, entries)
      if error or not vim.islist(entries) then
        finish(error or "Invalid GitHub release list")
        return
      end
      for _, entry in ipairs(entries) do
        local version = published_version(entry)
        if version and (not best_version or release.newer(version, best_version)) then
          best_version, best_entry = version, entry
        end
      end
      if #entries == page_size then
        scan(page + 1)
      elseif best_version then
        select_asset(best_version, best_entry, target, finish)
      else
        finish("No stable release for supported major " .. release.major)
      end
    end)
  end
  scan(1)
end

return release
