local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local tests = MiniTest.new_set()

local root = assert(vim.env.VENUE_READER_TEST_ROOT)
local manifest = require("venue-reader.release")
local target, system = manifest.platform()
local downloader = system == "Windows_NT" and "curl.exe" or "curl"
local extractor = system == "Windows_NT" and "tar.exe" or "tar"
local binary = system == "Windows_NT" and "venue-reader.exe" or "venue-reader"
local equal = MiniTest.expect.equality
local major, minor, patch = (manifest.series .. ".0"):match("^(%d+)%.(%d+)%.(%d+)$")
local compatible_patch = manifest.series .. "." .. (tonumber(patch) + 1)
local other_minor = major .. "." .. (tonumber(minor) + 1) .. ".0"
local unsupported_versions = {
  manifest.version .. "-rc.1",

  (tonumber(major) + 1) .. ".0.0",
  "broken",
}
if tonumber(major) > 0 then
  table.insert(unsupported_versions, (tonumber(major) - 1) .. ".0.0")
end

local function isolated(handler)
  local directory = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(directory, "p")
  local original_system, original_stdpath, original_exepath =
    vim.system, vim.fn.stdpath, vim.fn.exepath
  local previous = package.loaded["venue-reader.server"]

  MiniTest.finally(function()
    rawset(vim, "system", original_system)
    rawset(vim.fn, "stdpath", original_stdpath)
    rawset(vim.fn, "exepath", original_exepath)
    package.loaded["venue-reader.server"] = previous
    vim.fn.delete(directory, "rf")
  end)

  rawset(vim.fn, "stdpath", function(kind)
    return kind == "data" and directory or original_stdpath(kind)
  end)

  rawset(vim.fn, "exepath", function(name)
    return name == "venue-reader" and "" or original_exepath(name)
  end)

  rawset(vim, "system", function(command, options, callback)
    local replacement, response = handler(command)
    if response then
      vim.schedule(function()
        options.stdout(nil, response)
        callback({ code = 0 })
      end)
      return { kill = function() end }
    end
    return original_system(replacement or command, options, callback)
  end)
  package.loaded["venue-reader.server"] = nil
  return require("venue-reader.server"), directory
end

local function resolve(server, options, retry)
  local response
  server.resolve(options, function(error, argv, version)
    response = { error = error, argv = argv, version = version }
  end, retry)
  Lsp.wait(function()
    return response ~= nil
  end, "server acquisition")
  return response
end

local function history_count(message)
  local output = vim.api.nvim_exec2("messages", { output = true }).output
  return vim.fn.count(vim.split(output, "\n", { plain = true }), message)
end

tests["explicit command preserves argv and coalesces probes"] = function()
  local probes = 0
  local server = isolated(function(command)
    equal(command, { "wrapper", "--version" })
    probes = probes + 1
    return nil, "venue-reader " .. compatible_patch .. "\n"
  end)
  local answers = {}
  local options = { cmd = { "wrapper", "--stdio", "custom" } }
  for index = 1, 2 do
    server.resolve(options, function(error, argv, version)
      answers[index] = { error = error, argv = argv, version = version }
    end)
  end
  Lsp.wait(function()
    return #answers == 2
  end, "coalesced probes")
  equal(probes, 1)
  equal(answers[1].argv, options.cmd)
  equal(answers[2].version, compatible_patch)
  equal(answers[1].error, nil)
end

for _, version in ipairs(unsupported_versions) do
  tests["unsupported explicit version " .. version .. " is rechecked on each launch"] = function()
    local probes = 0
    local server = isolated(function()
      probes = probes + 1
      return nil, "venue-reader " .. version .. "\n"
    end)
    assert(resolve(server, { cmd = { "wrapper" } }).error)
    assert(resolve(server, { cmd = { "wrapper" } }).error)
    equal(probes, 2)
  end
end

tests["compatible PATH server is reused without installation"] = function()
  local probes = 0
  local server = isolated(function(command)
    equal(command, { "/existing/venue-reader", "--version" })
    probes = probes + 1
    return nil, "venue-reader " .. compatible_patch .. "\n"
  end)
  local exepath = vim.fn.exepath
  rawset(vim.fn, "exepath", function(name)
    return name == "venue-reader" and "/existing/venue-reader" or exepath(name)
  end)
  local result = resolve(server, { update_version = false })
  equal(result.error, nil)
  equal(result.argv, { "/existing/venue-reader", "--stdio" })
  equal(result.version, compatible_patch)
  equal(probes, 1)
end

tests["manual mode with no installed binary never starts a subprocess"] = function()
  local server = isolated(function()
    error("No subprocess expected")
  end)
  local result = resolve(server, { update_version = false })
  assert(result.error:find("No compatible server", 1, true))
  equal(server.status().state, "failed")
end

tests["incompatible release pin is rejected before download"] = function()
  local server = isolated(function()
    error("No subprocess expected")
  end)
  assert(resolve(server, { update_version = (tonumber(major) + 1) .. ".0.0" }).error)
end

local function archive_fixture(bad_hash, failure)
  if not manifest.pinned then
    MiniTest.skip(
      "Compatible release is not pinned; archive installation verification pending release"
    )
  end
  local artifact = manifest.artifacts[target]
  if not artifact then
    MiniTest.skip("No released archive for " .. target)
  end
  local archive = vim.fs.joinpath(root, ".test-deps", manifest.version, target, artifact.archive)
  assert(vim.fn.filereadable(archive) == 1, "Run make prepare for installation archive tests")
  local downloads = 0
  local server, directory = isolated(function(command)
    if failure then
      local replacement, response = failure(command)
      if replacement or response then
        return replacement, response
      end
    end
    if command[1] == downloader then
      downloads = downloads + 1
      local output = assert(vim.fn.index(command, "--output")) + 2
      if bad_hash then
        vim.fn.writefile({ "invalid archive" }, command[output])
      else
        assert(vim.uv.fs_copyfile(archive, command[output]))
      end
      return nil, ""
    end
  end)
  return server, directory, function()
    return downloads
  end
end

local function use_latest_manifest()
  local original = manifest.resolve
  local checks = 0
  MiniTest.finally(function()
    manifest.resolve = original
  end)
  manifest.resolve = function(selector, host, callback)
    equal(selector, "latest")
    equal(host, target)
    checks = checks + 1
    callback(nil, manifest)
  end
  return function()
    return checks
  end
end

tests["default discovery installs a missing release once and retains notices"] = function()
  local checks = use_latest_manifest()
  local server, directory, downloads = archive_fixture(false)
  local replies = {}
  for index = 1, 2 do
    server.resolve(nil, function(error, argv)
      replies[index] = { error = error, argv = argv }
    end)
  end
  Lsp.wait(function()
    return #replies == 2
  end, "local archive installation")
  equal(replies[1].error, nil)
  equal(downloads(), 1)
  equal(checks(), 1)
  local notice = ("venue-reader: Installed server %s at %s"):format(
    manifest.version,
    replies[1].argv[1]
  )
  equal(history_count(notice), 1)
  local installed = vim.fs.dirname(replies[1].argv[1])
  assert(installed:find(directory, 1, true))
  equal(vim.fn.filereadable(installed .. "/NOTICE"), 1)
  equal(vim.fn.filereadable(installed .. "/DEPENDENCY_LICENSES.txt"), 1)
  equal(resolve(server, {}).argv, replies[1].argv)
  equal(resolve(server, { update_version = false }).argv, replies[1].argv)
  equal(history_count(notice), 1)
  equal(downloads(), 1)
  equal(vim.fn.glob(directory .. "/venue-reader/*/*.tmp-*"), "")
end

tests["latest upgrades the managed server and retains the previous release"] = function()
  local previous = manifest.major .. ".0.0"
  if not manifest.newer(manifest.version, previous) then
    MiniTest.skip("The bundled release is the first version in its major")
  end
  local checks = use_latest_manifest()

  local older_path
  local server, directory, downloads = archive_fixture(false, function(command)
    if command[1] == older_path then
      return nil, "venue-reader " .. previous .. "\n"
    end
  end)
  older_path = vim.fs.joinpath(directory, "venue-reader", previous, target, binary)
  vim.fn.mkdir(vim.fs.dirname(older_path), "p")
  vim.fn.writefile({ "previous installation" }, older_path)
  equal(resolve(server, { update_version = false }).version, previous)
  equal(downloads(), 0)
  equal(checks(), 0)
  local updated = resolve(server, {})
  equal(updated.version, manifest.version)
  equal(
    history_count(
      ("venue-reader: Installed server %s at %s"):format(updated.version, updated.argv[1])
    ),
    1
  )
  equal(server.status().update_version, "latest")
  equal(checks(), 1)
  equal(resolve(server, { update_version = previous }).argv[1], older_path)
  equal(downloads(), 1)
end

tests["checksum failure publishes no runnable install and cleans staging"] = function()
  local server, directory, downloads = archive_fixture(true)
  local result = resolve(server, { update_version = manifest.version })
  assert(result.error:find("SHA-256 mismatch", 1, true))
  equal(downloads(), 1)
  equal(vim.fn.glob(directory .. "/venue-reader/*/*/" .. binary), "")
  equal(vim.fn.glob(directory .. "/venue-reader/*/*.tmp-*"), "")
  assert(resolve(server, { update_version = manifest.version }).error)
  equal(downloads(), 2)
end

tests["automatic latest keeps the working server after a checksum failure"] = function()
  local lookup = manifest.resolve
  MiniTest.finally(function()
    manifest.resolve = lookup
  end)
  local previous = manifest.major .. ".0.0"
  local selected = vim.tbl_extend("force", manifest, { version = other_minor })
  manifest.resolve = function(_, _, callback)
    callback(nil, selected)
  end
  local older_path
  local server, directory, downloads = archive_fixture(true, function(command)
    if command[1] == older_path then
      return nil, "venue-reader " .. previous
    end
  end)
  older_path = vim.fs.joinpath(directory, "venue-reader", previous, target, binary)
  vim.fn.mkdir(vim.fs.dirname(older_path), "p")
  vim.fn.writefile({ "working server" }, older_path)
  local reused = resolve(server, { update_version = "latest" })
  equal(reused.argv, { older_path, "--stdio" })
  equal(reused.version, previous)
  equal(server.status().target_version, selected.version)
  assert(server.status().update_error:find("SHA-256 mismatch", 1, true))
  local notice = "venue-reader: Automatic server update failed: Release SHA-256 mismatch."
    .. (" Using compatible server %s (managed)."):format(previous)
  equal(history_count(notice), 1)
  equal(downloads(), 1)
  assert(
    resolve(server, { update_version = selected.version }).error:find("SHA-256 mismatch", 1, true)
  )
  local manual_error
  server.install("latest", function(error)
    manual_error = error
  end)
  Lsp.wait(function()
    return manual_error ~= nil
  end, "manual checksum failure")
  assert(manual_error:find("SHA-256 mismatch", 1, true))
  equal(downloads(), 3)
  local installed_paths = vim.fn.glob(directory .. "/venue-reader/*/*/" .. binary, false, true)
  equal(vim.tbl_map(vim.fs.normalize, installed_paths), { older_path })
  equal(vim.fn.glob(directory .. "/venue-reader/*/*.tmp-*"), "")
end

for _, stage in ipairs({ "download", "inventory", "links", "extraction" }) do
  tests[stage .. " failure publishes nothing and removes staging"] = function()
    local server, directory = archive_fixture(false, function(command)
      if
        stage == "download" and command[1] == downloader
        or stage == "extraction" and command[1] == extractor and command[2] == "-xf"
      then
        return { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-c", "cquit 1" }
      elseif stage == "inventory" and command[1] == extractor and command[2] == "-tf" then
        return nil, "../escape\n"
      elseif stage == "links" and command[1] == extractor and command[2] == "-tvf" then
        return nil, "lrwxrwxrwx link -> /outside\n"
      end
    end)
    assert(resolve(server, { update_version = manifest.version }).error)
    equal(vim.fn.glob(directory .. "/venue-reader/*/*/" .. binary), "")
    equal(vim.fn.glob(directory .. "/venue-reader/*/*.tmp-*"), "")
  end
end

tests["incompatible PATH candidate falls back to compatible managed installation"] = function()
  local server, _, downloads = archive_fixture(false, function(command)
    if command[1] == "/unsupported/venue-reader" then
      return nil, "venue-reader " .. (tonumber(major) + 1) .. ".0.0" .. "\n"
    end
  end)
  local installed = resolve(server, { update_version = manifest.version })
  equal(installed.error, nil)
  local exepath = vim.fn.exepath
  rawset(vim.fn, "exepath", function(name)
    return name == "venue-reader" and "/unsupported/venue-reader" or exepath(name)
  end)
  local reused = resolve(server, { update_version = false }, true)
  equal(reused.error, nil)
  equal(reused.argv, installed.argv)
  equal(downloads(), 1)
  assert(server.status().reason:find((tonumber(major) + 1) .. ".0.0", 1, true))
end

tests["publication loser reuses winner and preserves its files"] = function()
  local server, directory = archive_fixture(false)
  local rename = vim.uv.fs_rename
  local publications = 0
  MiniTest.finally(function()
    rawset(vim.uv, "fs_rename", rename)
  end)
  rawset(vim.uv, "fs_rename", function(source, destination)
    publications = publications + 1
    assert(rename(source, destination))
    vim.fn.writefile({ "another process owns this publication" }, destination .. "/winner")
    return nil, "EEXIST: another process published first"
  end)
  local result = resolve(server, { update_version = manifest.version })
  equal(result.error, nil)
  equal(publications, 1)
  local installed = vim.fs.dirname(result.argv[1])
  equal(vim.fn.filereadable(installed .. "/" .. binary), 1)
  equal(vim.fn.readfile(installed .. "/winner"), { "another process owns this publication" })
  equal(vim.fn.glob(directory .. "/venue-reader/*/*.tmp-*"), "")
end

tests["invalid managed binary error includes its path and preserves installation"] = function()
  local server = archive_fixture(false)
  local installed = resolve(server, { update_version = manifest.version })
  equal(installed.error, nil)
  vim.fn.writefile({ "not an executable" }, installed.argv[1])
  local failed = resolve(server, { update_version = false }, true)
  assert(failed.error and failed.error:find(installed.argv[1], 1, true))
  equal(vim.fn.filereadable(installed.argv[1]), 1)
end
tests["next resolution sees a replaced executable and accepts a different minor"] = function()
  local version = manifest.version
  local server = isolated(function()
    return nil, "venue-reader " .. version .. "\n"
  end)
  local command = { cmd = { "/external/venue-reader" } }
  equal(resolve(server, command).version, manifest.version)
  version = other_minor
  equal(resolve(server, command).version, other_minor)
  version = (tonumber(major) + 1) .. ".0.0"
  assert(resolve(server, command).error)
end

tests["automatic latest picks the newer managed minor over an older PATH version"] = function()
  local original = manifest.resolve
  MiniTest.finally(function()
    manifest.resolve = original
  end)
  local lookup_error
  manifest.resolve = function(selector, _, callback)
    equal(selector, "latest")
    if lookup_error then
      callback(lookup_error)
    else
      callback(nil, { version = other_minor })
    end
  end
  local external = "/existing/venue-reader"
  local server, directory = isolated(function(command)
    return nil,
      "venue-reader " .. (command[1] == external and manifest.version or other_minor) .. "\n"
  end)
  local managed = vim.fs.joinpath(directory, "venue-reader", other_minor, target, binary)
  vim.fn.mkdir(vim.fs.dirname(managed), "p")
  vim.fn.writefile({}, managed)
  rawset(vim.fn, "exepath", function()
    return external
  end)
  local selected = resolve(server, { update_version = "latest" })
  equal(selected.argv, { managed, "--stdio" })
  rawset(vim.fn, "exepath", function()
    return ""
  end)
  lookup_error = "Invalid GitHub release metadata"
  equal(resolve(server, { update_version = "latest" }).argv, selected.argv)
  equal(server.status().update_error, lookup_error)
  equal(server.status().state, "ready")
  local manual_error
  server.install("latest", function(error)
    manual_error = error
  end)
  equal(manual_error, lookup_error)
  vim.fn.delete(managed)
  equal(resolve(server, { update_version = "latest" }).error, lookup_error)
end

tests["latest reuses a matching external version on a platform without an archive"] = function()
  local lookup = manifest.resolve
  MiniTest.finally(function()
    manifest.resolve = lookup
  end)
  manifest.resolve = function(_, _, callback)
    callback(nil, { version = other_minor, artifacts = {} })
  end
  local external_version = other_minor
  local server = isolated(function(command)
    equal(command, { "/external/venue-reader", "--version" })
    return nil, "venue-reader " .. external_version
  end)
  rawset(vim.fn, "exepath", function()
    return "/external/venue-reader"
  end)
  equal(resolve(server, { update_version = "latest" }).version, other_minor)
  equal(server.status().update_error, nil)
  external_version = manifest.version
  equal(resolve(server, { update_version = "latest" }).version, external_version)
  equal(server.status().target_version, other_minor)
  assert(server.status().update_error:find("No release archive", 1, true))
  local failure
  server.install("latest", function(error)
    failure = error
  end)
  assert(failure:find("No release archive", 1, true))
end

return tests
