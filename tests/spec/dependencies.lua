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

return tests
