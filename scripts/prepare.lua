local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
local success, result = pcall(function()
  local dependencies = dofile(root .. "/scripts/dependencies.lua")
  dependencies.prepare_tests()
  if arg[1] == "--tests-only" then
    return "test dependencies"
  end
  return dependencies.prepare(arg[1] or vim.env.VENUE_READER_TEST_ARCHIVE)
end)
if not success then
  io.stderr:write(tostring(result) .. "\n")
  vim.cmd("cquit 1")
end
print("Prepared and verified: " .. result)
