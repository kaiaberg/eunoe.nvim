local M = {}

M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

function M.eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error((msg and (msg .. ": ") or "") .. vim.inspect(actual) .. "\n  ~= expected " .. vim.inspect(expected), 2)
  end
end

function M.truthy(v, msg)
  if not v then
    error(msg or "expected a truthy value", 2)
  end
end

--- Path of a fixture file.
function M.fixture(name)
  return M.root .. "/tests/fixtures/" .. name
end

--- Lines of a fixture file.
function M.lines(name)
  return vim.fn.readfile(M.fixture(name))
end

--- Run the loop until `done()` is true or the timeout passes.
function M.wait(done, ms)
  M.truthy(vim.wait(ms or 2000, done, 5), "timed out")
end

return M
