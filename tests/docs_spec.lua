local h = require("helpers")
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local HELP = root .. "/doc/eunoe.txt"

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

--- The Lua code blocks of the README (```lua) and the help file (>lua).
local function lua_blocks()
  local blocks = {}
  for code in read(root .. "/README.md"):gmatch("```lua\n(.-)\n```") do
    blocks[#blocks + 1] = { "README", code }
  end
  local lines, cur = vim.fn.readfile(HELP), nil
  for _, line in ipairs(lines) do
    if cur then
      if line:match("^%s*<") or line:match("^%S") then
        blocks[#blocks + 1] = { "help", table.concat(cur, "\n") }
        cur = nil
      else
        cur[#cur + 1] = line
      end
    elseif line:match(">lua$") then
      cur = {}
    end
  end
  return blocks
end

return {
  ["every Lua example compiles"] = function()
    local blocks = lua_blocks()
    h.truthy(#blocks >= 10, "found " .. #blocks .. " blocks")
    for _, b in ipairs(blocks) do
      -- A block is code, or a value such as the status table.
      local ok = loadstring(b[2]) or loadstring("return " .. b[2])
      h.truthy(ok, ("%s example doesn't compile:\n%s"):format(b[1], b[2]))
    end
  end,
  ["the README's plain statusline example works"] = function()
    local code
    for _, b in ipairs(lua_blocks()) do
      if b[1] == "README" and b[2]:find('pattern = "EunoeStatus"', 1, true) and b[2]:find("statusline", 1, true) then
        code = b[2]
      end
    end
    h.truthy(code, "example not found")
    local view = require("eunoe.view")
    assert(loadstring(code))()
    local win = view.show({ { n = 1, prompt = "Hi", reply = "Yo" } }, {
      name = "eunoe://test/statusline",
      session = { reader = "claude", id = "abc", label = "Claude Code" },
      truncate = false,
      width = 60,
      focus = true,
      handlers = { close = view.close, reload = function() end },
    })
    h.eq(vim.wo[win].statusline, "Claude Code · turn 1/1 · default")
    view.close()
    vim.api.nvim_clear_autocmds({ event = "User", pattern = "EunoeStatus" })
  end,
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
