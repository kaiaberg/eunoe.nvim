-- Minimal test runner: nvim -n --clean -l tests/run.lua [file ...]
-- EUNOE_TEST=<Lua pattern> runs only the tests whose names match.
-- Dependency-free on purpose. Each spec file returns a table of
-- name -> function; a test fails if it errors.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
package.path =
  table.concat({ root .. "/lua/?.lua", root .. "/lua/?/init.lua", root .. "/tests/?.lua", package.path }, ";")
vim.opt.rtp:prepend(root)

local files = #arg > 0 and arg or vim.fn.glob(root .. "/tests/**/*_spec.lua", false, true)
local pass, fail = 0, 0
for _, file in ipairs(files) do
  local specs = dofile(file)
  local names = vim.tbl_keys(specs)
  table.sort(names)
  local only = vim.env.EUNOE_TEST
  if only and only ~= "" then
    names = vim.tbl_filter(function(n)
      return n:find(only) ~= nil
    end, names)
  end
  for _, name in ipairs(names) do
    local ok, err = pcall(specs[name])
    if ok then
      pass = pass + 1
    else
      fail = fail + 1
      io.stdout:write(("FAIL %s :: %s\n  %s\n"):format(vim.fn.fnamemodify(file, ":t"), name, err))
    end
  end
end
io.stdout:write(("%d passed, %d failed\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
