local h = require("helpers")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local HELP = root .. "/doc/eunoe.txt"

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

return {
  [":helptags succeeds and :help finds the main tags"] = function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp .. "/doc", "p")
    vim.fn.writefile(vim.fn.readfile(HELP), tmp .. "/doc/eunoe.txt")
    vim.cmd.helptags(tmp .. "/doc")
    vim.opt.rtp:prepend(tmp)
    for _, tag in ipairs({ "eunoe.txt", ":Eunoe", ":Eunoe-all", "eunoe-config", "eunoe.turns()", "eunoe-readers" }) do
      vim.cmd.help(tag)
      h.eq(vim.bo.filetype, "help", tag)
      vim.cmd.helpclose()
    end
    vim.opt.rtp:remove(tmp)
  end,
  ["every |link| in the help file resolves"] = function()
    local text = read(HELP)
    local defined = {}
    for tag in text:gmatch("%*([^%s*]+)%*") do
      defined[tag] = true
    end
    for link in text:gmatch("|([^%s|]+)|") do
      -- An exact help tag: `:help` itself would also accept a partial match.
      local builtin = vim.tbl_contains(vim.fn.getcompletion(link, "help"), link)
      h.truthy(defined[link] or builtin, "unresolved |" .. link .. "|")
    end
  end,
  ["lines fit in 78 columns"] = function()
    for i, line in ipairs(vim.fn.readfile(HELP)) do
      h.truthy(vim.fn.strdisplaywidth(line) <= 78, ("line %d is too long: %s"):format(i, line))
    end
  end,
  ["every option, <Plug> mapping and API function is documented"] = function()
    vim.cmd("runtime plugin/eunoe.lua")
    local help, readme = read(HELP), read(root .. "/README.md")
    local config = require("eunoe.config")
    for key, value in pairs(config.defaults) do
      local names = { key }
      if type(value) == "table" then
        names = vim.tbl_map(function(k)
          return key .. "." .. k
        end, vim.tbl_keys(value))
      end
      for _, name in ipairs(names) do
        local leaf = name:match("[^.]+$")
        h.truthy(help:find(name, 1, true) or help:find("`" .. leaf .. "`", 1, true), name .. " undocumented in :help")
        h.truthy(readme:find(leaf .. " =", 1, true), name .. " missing from the README defaults")
      end
    end
    for _, plug in ipairs({ "eunoe-toggle", "eunoe-quote" }) do
      h.truthy(vim.fn.maparg("<Plug>(" .. plug .. ")", plug == "eunoe-quote" and "x" or "n") ~= "", plug)
      h.truthy(help:find("*<Plug>(" .. plug .. ")*", 1, true), plug .. " undocumented in :help")
      h.truthy(readme:find("<Plug>(" .. plug .. ")", 1, true), plug .. " missing from the README")
    end
    for name, fn in pairs(require("eunoe")) do
      if type(fn) == "function" and name ~= "load" then
        h.truthy(help:find("*eunoe." .. name .. "()*", 1, true), "eunoe." .. name .. "() undocumented in :help")
      end
    end
  end,
}
