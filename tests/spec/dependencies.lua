local MiniTest = require("mini.test")

local function isolated(check)
  local directory = vim.fn.tempname()
  MiniTest.finally(function()
    vim.fn.delete(directory, "rf")
  end)
  local root = assert(vim.env.VENUE_READER_TEST_ROOT)
  for _, name in ipairs({ "scripts", "tests", "lua/venue-reader" }) do
    vim.fn.mkdir(directory .. "/" .. name, "p")
  end
  for _, name in ipairs({
    "scripts/dependencies.lua",
    "tests/dependencies.json",
    "lua/venue-reader/release.json",
    "lua/venue-reader/release.lua",
  }) do
    assert(vim.uv.fs_copyfile(root .. "/" .. name, directory .. "/" .. name))
  end
  check(dofile(directory .. "/scripts/dependencies.lua"), directory)
end

local tests = MiniTest.new_set()

tests["unprepared tests fail without downloading"] = function()
  isolated(function(dependencies, directory)
    MiniTest.expect.error(dependencies.verify, "Pinned server is missing")
    MiniTest.expect.equality(vim.fn.isdirectory(directory .. "/.test-deps"), 0)
  end)
end

tests["checksum failure publishes no installation"] = function()
  isolated(function(dependencies, directory)
    local archive = directory .. "/bad.tar.gz"
    vim.fn.writefile({ "not a release archive" }, archive)
    MiniTest.expect.error(function()
      dependencies.prepare(archive)
    end, "SHA%-256 mismatch")
    MiniTest.expect.equality(vim.fn.isdirectory(directory .. "/.test-deps"), 0)
  end)
end

tests["missing framework fails without downloading"] = function()
  isolated(function(dependencies, directory)
    MiniTest.expect.error(dependencies.verify_tests, "mini.test is missing")
    MiniTest.expect.equality(vim.fn.isdirectory(directory .. "/.test-deps"), 0)
  end)
end

tests["changing only the pin updates preparation URL and runtime compatibility"] = function()
  isolated(function(_, directory)
    local metadata_path = directory .. "/lua/venue-reader/release.json"
    local metadata = vim.json.decode(table.concat(vim.fn.readfile(metadata_path), "\n"))
    metadata.version = "7.13.29"
    vim.fn.writefile({ vim.json.encode(metadata) }, metadata_path)
    local dependencies = dofile(directory .. "/scripts/dependencies.lua")
    MiniTest.expect.equality(dependencies.version, "7.13.29")

    local original_system = vim.system
    local previous_release = package.loaded["venue-reader.release"]
    MiniTest.finally(function()
      rawset(vim, "system", original_system)
      package.loaded["venue-reader.release"] = previous_release
    end)
    local download_url
    rawset(vim, "system", function(command, options, callback)
      if command[1] == "curl" then
        download_url = command[#command]
        return {
          wait = function()
            return { code = 1, stderr = "download stopped by test" }
          end,
        }
      end
      MiniTest.expect.equality(command[2], "--version")
      vim.schedule(function()
        options.stdout(nil, "venue-reader " .. command[1] .. "\n")
        callback({ code = 0 })
      end)
      return { kill = function() end }
    end)
    MiniTest.expect.error(function()
      dependencies.prepare()
    end, "download stopped by test")
    assert(download_url:find("/releases/download/v7.13.29/", 1, true))

    package.loaded["venue-reader.release"] = dofile(directory .. "/lua/venue-reader/release.lua")
    local root = assert(vim.env.VENUE_READER_TEST_ROOT)
    local server = dofile(root .. "/lua/venue-reader/server.lua")
    for _, candidate in ipairs({ { "7.13.30", true }, { "7.14.0", false } }) do
      local response
      server.resolve({ cmd = { candidate[1] } }, function(err)
        response = { accepted = err == nil }
      end)
      assert(
        vim.wait(1000, function()
          return response ~= nil
        end, 10),
        "version probe timed out"
      )
      MiniTest.expect.equality(response.accepted, candidate[2])
    end
  end)
end

return tests
