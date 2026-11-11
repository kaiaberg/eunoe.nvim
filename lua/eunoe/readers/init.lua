--- The reader registry. A reader knows one agent: how to find its sessions
--- and how to parse a transcript into turns. Built-in readers register
--- through the same interface as external ones.
---
--- ```lua
--- require("eunoe").register_reader("myagent", {
---   -- Sessions for this Neovim (see eunoe.Context and eunoe.Session):
---   -- `via = "parent"` for one whose pid is among ctx.chain (Neovim was
---   -- started from it), `via = "cwd"` for one running in ctx.cwd.
---   detect = function(ctx) return { { id = "…", pid = 123, via = "parent", transcript = "/path" } } end,
---   -- Parse `transcript` (a path, or whatever `detect` put there) into
---   -- turns ({ n, prompt, reply, time? }), then call cb(turns), or
---   -- cb(nil, err). A missing transcript: cb(nil, "ENOENT: …").
---   read = function(transcript, cb) cb({ { n = 1, prompt = "…", reply = "…" } }) end,
--- })
--- ```
local M = {}

---@class eunoe.Reader
---@field detect fun(ctx: eunoe.Context): eunoe.Session[]
---@field read fun(transcript: string, cb: fun(turns: eunoe.Turn[]?, err: any))

local BUILTIN = { claude = "eunoe.readers.claude" }
local BUILTIN_ORDER = { "claude" }

local registry, order, loaded_builtins = {}, {}, false

local function add(name, reader)
  if registry[name] == nil then
    order[#order + 1] = name
  end
  registry[name] = reader
end

local function load_builtins()
  if loaded_builtins then
    return
  end
  loaded_builtins = true
  for _, name in ipairs(BUILTIN_ORDER) do
    -- A reader registered under a built-in name (or removed with `false`)
    -- before first use wins.
    if registry[name] == nil then
      add(name, require(BUILTIN[name]))
    end
  end
end

--- Register a reader, replace one of the same name (including a built-in),
--- or remove one with `false`.
---@param name string
---@param reader eunoe.Reader|false
function M.register(name, reader)
  if type(name) ~= "string" or not name:match("^[%w_-]+$") then
    error(("eunoe: reader name must be letters, digits, '-' or '_', got %s"):format(vim.inspect(name)), 2)
  end
  if reader ~= false then
    if type(reader) ~= "table" then
      error(("eunoe: reader %q must be a table with detect and read functions"):format(name), 2)
    end
    for _, field in ipairs({ "detect", "read" }) do
      if not vim.is_callable(reader[field]) then
        error(("eunoe: reader %q needs a %s function"):format(name, field), 2)
      end
    end
  end
  add(name, reader)
end

--- The registered readers and their detection order (removed ones left out).
---@return table<string, eunoe.Reader>, string[]
function M.all()
  load_builtins()
  local readers, names = {}, {}
  for _, name in ipairs(order) do
    if registry[name] then
      readers[name] = registry[name]
      names[#names + 1] = name
    end
  end
  return readers, names
end

--- A registered reader by name.
---@param name string
---@return eunoe.Reader?
function M.get(name)
  load_builtins()
  return registry[name] or nil
end

--- Forget all registrations (for tests).
function M._reset()
  registry, order, loaded_builtins = {}, {}, false
end

return M
