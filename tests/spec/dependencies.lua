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
    "lua/venue-reader/grammar.json",
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

tests["central manifest controls artifact URLs and required runtime series"] = function()
  isolated(function(_, directory)
    local metadata_path = directory .. "/lua/venue-reader/release.json"
    local metadata = vim.json.decode(table.concat(vim.fn.readfile(metadata_path), "\n"))
    metadata.version = "7.13.29"
    metadata.series = "7.13"
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

tests["prepared sources and parser reject tampering and stale pins"] = function()
  isolated(function(dependencies, directory)
    local root = assert(vim.env.VENUE_READER_TEST_ROOT)
    for _, name in ipairs({
      "mini.test",
      "nvim-treesitter",
      "nvim-treesitter-textobjects",
      "tree-sitter-fix",
      "snacks.nvim",
    }) do
      local result = vim
        .system({
          "git",
          "clone",
          "--no-hardlinks",
          root .. "/.test-deps/" .. name,
          directory .. "/.test-deps/" .. name,
        })
        :wait(5000)
      assert(result.code == 0, result.stderr)
    end
    local relative = "/.test-deps/treesitter/"
    vim.fn.mkdir(directory .. relative .. "runtime/parser", "p")
    for _, name in ipairs({ "build.json", "runtime/parser/fix.so" }) do
      assert(vim.uv.fs_copyfile(root .. relative .. name, directory .. relative .. name))
    end
    dependencies.verify_tests()
    local snacks_init = directory .. "/.test-deps/snacks.nvim/lua/snacks/init.lua"
    local original = vim.fn.readfile(snacks_init)
    vim.fn.writefile({ "-- modified dependency" }, snacks_init)
    MiniTest.expect.error(dependencies.verify_tests, "git failed")
    vim.fn.writefile(original, snacks_init)
    local manifest_path = directory .. "/tests/dependencies.json"
    local manifest = vim.json.decode(table.concat(vim.fn.readfile(manifest_path), "\n"))
    manifest.snacks.commit = string.rep("0", 40)
    vim.fn.writefile({ vim.json.encode(manifest) }, manifest_path)
    MiniTest.expect.error(function()
      dofile(directory .. "/scripts/dependencies.lua").verify_tests()
    end, "snacks.nvim revision differs from pin")
    dependencies.verify_tests()
    local binary = directory .. relative .. "runtime/parser/fix.so"
    vim.fn.writefile({ "not the prepared parser" }, binary)
    MiniTest.expect.error(dependencies.verify_tests, "FIX test parser checksum differs")
    assert(vim.uv.fs_copyfile(root .. relative .. "runtime/parser/fix.so", binary))
    local metadata = directory .. relative .. "build.json"
    local build = vim.json.decode(table.concat(vim.fn.readfile(metadata), "\n"))
    build.commit = "different grammar revision"
    vim.fn.writefile({ vim.json.encode(build) }, metadata)
    MiniTest.expect.error(dependencies.verify_tests, "FIX test parser source revision differs")
  end)
end

return tests
