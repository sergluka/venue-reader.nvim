local MiniTest = require("mini.test")
local Lsp = require("tests.support.lsp")
local tests = MiniTest.new_set()

local root = assert(vim.env.VENUE_READER_TEST_ROOT)
local release_file = assert(io.open(root .. "/lua/venue-reader/release.json", "rb"))
local manifest = vim.json.decode(release_file:read("*a"))

local equal = MiniTest.expect.equality

release_file:close()

local function isolated(handler)
  local directory = vim.fn.tempname()
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

tests["explicit command preserves argv and coalesces probes"] = function()
  local probes = 0
  local server = isolated(function(command)
    equal(command, { "wrapper", "--version" })
    probes = probes + 1
    return nil, "venue-reader 0.1.4\n"
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
  equal(answers[2].version, "0.1.4")
  equal(answers[1].error, nil)
end

for _, version in ipairs({ "0.1.0-rc.1", "0.2.0", "1.0.0", "broken" }) do
  tests["unsupported explicit version " .. version .. " fails until explicit retry"] = function()
    local probes = 0
    local server = isolated(function()
      probes = probes + 1
      return nil, "venue-reader " .. version .. "\n"
    end)
    assert(resolve(server, { cmd = { "wrapper" } }).error)
    assert(resolve(server, { cmd = { "wrapper" } }).error)
    equal(probes, 1)
    assert(resolve(server, { cmd = { "wrapper" } }, true).error)
    equal(probes, 2)
  end
end

tests["manual mode with no installed binary never starts a subprocess"] = function()
  local server = isolated(function()
    error("No subprocess expected")
  end)
  local result = resolve(server, { auto_install = false })
  assert(result.error:find("No compatible server", 1, true))
  equal(server.status().state, "failed")
end

local function archive_fixture(bad_hash, failure)
  local system = vim.uv.os_uname()
  if system.sysname ~= "Linux" or system.machine ~= "x86_64" then
    MiniTest.skip("Local released archive fixture requires Linux x86_64")
  end
  local archive = root
    .. "/.test-deps/"
    .. manifest.version
    .. "/x86_64-unknown-linux-gnu/"
    .. manifest.artifacts["x86_64-unknown-linux-gnu"].archive
  assert(vim.fn.filereadable(archive) == 1, "Run make prepare for installation archive tests")
  local downloads = 0
  local server, directory = isolated(function(command)
    if failure then
      local replacement, response = failure(command)
      if replacement or response then
        return replacement, response
      end
    end
    if command[1] == "curl" then
      downloads = downloads + 1
      local output = assert(vim.fn.index(command, "--output")) + 2
      return { "cp", archive, command[output] }
    elseif bad_hash and command[1] == "sha256sum" then
      return nil, string.rep("0", 64) .. "  archive\n"
    end
  end)
  return server, directory, function()
    return downloads
  end
end

tests["released archive installs once and retains notices"] = function()
  local server, directory, downloads = archive_fixture(false)
  local replies = {}
  for index = 1, 2 do
    server.resolve({}, function(error, argv)
      replies[index] = { error = error, argv = argv }
    end)
  end
  Lsp.wait(function()
    return #replies == 2
  end, "local archive installation")
  equal(replies[1].error, nil)
  equal(downloads(), 1)
  local installed = vim.fs.dirname(replies[1].argv[1])
  assert(installed:find(directory, 1, true))
  equal(vim.fn.filereadable(installed .. "/NOTICE"), 1)
  equal(vim.fn.filereadable(installed .. "/DEPENDENCY_LICENSES.txt"), 1)
  equal(resolve(server, {}, true).error, nil)
  equal(downloads(), 1)
  equal(vim.fn.glob(directory .. "/venue-reader/*/*.tmp-*"), "")
end

tests["checksum failure publishes no runnable install and cleans staging"] = function()
  local server, directory, downloads = archive_fixture(true)
  local result = resolve(server, {})
  assert(result.error:find("SHA-256 mismatch", 1, true))
  equal(downloads(), 1)
  equal(vim.fn.glob(directory .. "/venue-reader/*/*/venue-reader"), "")
  equal(vim.fn.glob(directory .. "/venue-reader/*/*.tmp-*"), "")
  assert(resolve(server, {}).error)
  equal(downloads(), 1)
end

for _, stage in ipairs({ "download", "inventory", "links", "extraction" }) do
  tests[stage .. " failure publishes nothing and removes staging"] = function()
    local server, directory = archive_fixture(false, function(command)
      if
        stage == "download" and command[1] == "curl"
        or stage == "extraction" and command[1] == "tar" and command[2] == "-xf"
      then
        return { "false" }
      elseif stage == "inventory" and command[1] == "tar" and command[2] == "-tf" then
        return nil, "../escape\n"
      elseif stage == "links" and command[1] == "tar" and command[2] == "-tvf" then
        return nil, "lrwxrwxrwx link -> /outside\n"
      end
    end)
    assert(resolve(server, {}).error)
    equal(vim.fn.glob(directory .. "/venue-reader/*/*/venue-reader"), "")
    equal(vim.fn.glob(directory .. "/venue-reader/*/*.tmp-*"), "")
  end
end

tests["incompatible PATH candidate falls back to compatible managed installation"] = function()
  local server, _, downloads = archive_fixture(false, function(command)
    if command[1] == "/unsupported/venue-reader" then
      return nil, "venue-reader 0.2.0\n"
    end
  end)
  local installed = resolve(server, {})
  equal(installed.error, nil)
  local exepath = vim.fn.exepath
  rawset(vim.fn, "exepath", function(name)
    return name == "venue-reader" and "/unsupported/venue-reader" or exepath(name)
  end)
  local reused = resolve(server, {}, true)
  equal(reused.error, nil)
  equal(reused.argv, installed.argv)
  equal(downloads(), 1)
  assert(server.status().reason:find("0.2.0", 1, true))
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
  local result = resolve(server, {})
  equal(result.error, nil)
  equal(publications, 1)
  local installed = vim.fs.dirname(result.argv[1])
  equal(vim.fn.filereadable(installed .. "/venue-reader"), 1)
  equal(vim.fn.readfile(installed .. "/winner"), { "another process owns this publication" })
  equal(vim.fn.glob(directory .. "/venue-reader/*/*.tmp-*"), "")
end

tests["invalid managed binary error includes its path and preserves installation"] = function()
  local server = archive_fixture(false)
  local installed = resolve(server, {})
  equal(installed.error, nil)
  vim.fn.writefile({ "not an executable" }, installed.argv[1])
  local failed = resolve(server, {}, true)
  assert(failed.error and failed.error:find(installed.argv[1], 1, true))
  equal(vim.fn.filereadable(installed.argv[1]), 1)
end
return tests
