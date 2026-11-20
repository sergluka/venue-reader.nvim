local MiniTest = require("mini.test")

local tests = MiniTest.new_set()
local equal = MiniTest.expect.equality
local target = "x86_64-unknown-linux-gnu"
local archive = "venue-reader-" .. target .. ".tar.gz"
local digest = string.rep("a", 64)

local manifest = require("venue-reader.release")
local other_major = tostring(tonumber(manifest.major) + 1)
local first_remote_patch = tonumber(manifest.version:match("(%d+)$")) + 1

local function version(minor, patch_offset)
  return ("%s.%d.%d"):format(manifest.major, minor, first_remote_patch + (patch_offset or 0))
end

local function entry(server_version)
  return {
    tag_name = "v" .. server_version,
    draft = false,
    prerelease = false,
    assets = { { name = archive, digest = "sha256:" .. digest, state = "uploaded" } },
  }
end

local function fixture(reply)
  local root = assert(vim.env.VENUE_READER_TEST_ROOT)
  local release = dofile(root .. "/lua/venue-reader/release.lua")
  local original = vim.system
  local requests = {}
  MiniTest.finally(function()
    rawset(vim, "system", original)
  end)
  rawset(vim, "system", function(command, _, callback)
    local url = command[#command]
    requests[#requests + 1] = url
    local response, status, stderr = reply(url)
    if stderr then
      callback({ code = status, stderr = stderr })
    else
      callback({ code = 0, stdout = vim.json.encode(response) .. "\n" .. (status or "200") })
    end
  end)
  local function resolve(selector, refresh)
    local result
    release.resolve(selector, target, function(error, selected)
      result = { error = error, selected = selected }
    end, refresh)
    assert(
      vim.wait(1000, function()
        return result ~= nil
      end, 10),
      "release resolution timed out"
    )
    return result
  end
  return resolve, requests, release
end

tests["latest scans all release pages and caches the selected stable release"] = function()
  local first = {}
  for index = 1, 20 do
    first[index] = entry(other_major .. ".0." .. index)
  end
  first[2] = entry(version(9))
  local draft, preview = entry(version(98)), entry(version(99))
  draft.draft, preview.prerelease = true, true
  local second = { draft, preview, entry(version(10, 1) .. "-rc.1"), entry(version(10)) }
  local pages = { first, second, { entry(version(11)) } }
  local resolve, requests = fixture(function()
    return table.remove(pages, 1)
  end)
  local result = resolve("latest")
  equal(result.error, nil)
  equal(result.selected.version, version(10))
  equal(result.selected.artifacts[target], { archive = archive, sha256 = digest })
  equal(resolve("latest").selected.version, version(10))
  equal(#requests, 2)
  assert(vim.endswith(requests[1], "&page=1"))
  assert(vim.endswith(requests[2], "&page=2"))
  equal(resolve("latest", true).selected.version, version(11))
  assert(vim.endswith(requests[3], "&page=1"))
end

tests["missing or unverified assets prevent selection of an older release"] = function()
  local newest = entry(version(19, 1))
  local resolve = fixture(function()
    return { entry(version(19)), newest }
  end)
  newest.assets[1].digest = vim.NIL
  local result = resolve("latest")
  assert(result.error:find("invalid SHA-256", 1, true))
  equal(result.selected, nil)
  newest.assets = {}
  result = resolve("latest")
  equal(result.error, nil)
  equal(result.selected.version, version(19, 1))
  equal(result.selected.artifacts, {})
end

tests["latest retries while a new release is missing the platform archive"] = function()
  local published = { entry(version(19)) }
  local resolve, requests = fixture(function()
    return published
  end)
  equal(resolve("latest").selected.version, version(19))

  local newest = entry(version(20))
  local assets = newest.assets
  newest.assets = {}
  table.insert(published, newest)
  local pending = resolve("latest", true)
  equal(pending.selected.version, version(20))
  equal(pending.selected.artifacts, {})

  newest.assets = assets
  local complete = resolve("latest")
  equal(complete.error, nil)
  equal(complete.selected.version, version(20))
  equal(complete.selected.artifacts[target], { archive = archive, sha256 = digest })
  equal(#requests, 3)
  equal(resolve("latest").selected, complete.selected)
  equal(#requests, 3)
end

tests["exact selection trusts the bundled pin and checks remote release identity"] = function()
  local resolve, requests, release = fixture(function(url)
    assert(vim.endswith(url, "/releases/tags/v" .. version(21, 1)))
    return entry(version(21, 2))
  end)
  equal(resolve(release.version).selected.artifacts[target], release.artifacts[target])
  assert(resolve(manifest.major .. ".01.1").error)
  assert(resolve(other_major .. ".0.0").error)
  equal(#requests, 0)
  local result = resolve(version(21, 1))
  assert(result.error:find("Missing stable release", 1, true))
  equal(result.selected, nil)
  equal(#requests, 1)
end

tests["release lookup reports HTTP, invalid response and curl errors"] = function()
  local status, stderr = "503", nil
  local resolve = fixture(function()
    return { message = "release API unavailable" }, status, stderr
  end)
  equal(resolve("latest").error, "GitHub release metadata returned HTTP 503")
  status = "404"
  equal(resolve(version(15, 3)).error, "GitHub release metadata returned HTTP 404")
  status = "200"
  equal(resolve("latest").error, "Invalid GitHub release list")
  status, stderr = 6, "Could not resolve host"
  equal(
    resolve("latest").error,
    "Cannot read release metadata: curl exited 6: Could not resolve host"
  )
end

return tests
