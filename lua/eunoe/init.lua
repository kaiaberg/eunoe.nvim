--- eunoe.nvim: show a coding agent's conversation while its screen is
--- hidden behind your editor.
local M = {}

local config = require("eunoe.config")

--- Optional; eunoe works with the defaults.
---@param opts table?
function M.setup(opts)
  config.setup(opts)
end

local function notify(msg, level)
  vim.notify("eunoe: " .. msg, level or vim.log.levels.INFO)
end

-- The session picked last, so a reload doesn't ask again when several
-- sessions match the cwd.
local last_pid

local function choose(sessions, cb)
  if #sessions == 1 then
    return cb(sessions[1])
  end
  for _, s in ipairs(sessions) do
    if s.pid == last_pid then
      return cb(s)
    end
  end
  vim.ui.select(sessions, {
    prompt = "eunoe: several sessions run in this directory",
    format_item = function(s)
      local when = s.updated and os.date("%H:%M", math.floor(s.updated / 1000)) or "?"
      return ("%s  (%s, updated %s, pid %d)"):format(s.name or s.id, s.reader, when, s.pid)
    end,
  }, function(s)
    if s then
      cb(s)
    end
  end)
end

--- Find the session and read its turns.
---@param cb fun(session: eunoe.Session, turns: eunoe.Turn[])
function M.load(cb)
  local session = require("eunoe.session")
  session.lookup(function(sessions, ctx)
    if #sessions == 0 then
      return notify(
        ("no agent session found: none among Neovim's parent processes, none running in %s"):format(ctx.cwd),
        vim.log.levels.WARN
      )
    end
    choose(sessions, function(s)
      last_pid = s.pid
      if not s.transcript then
        return cb(s, {})
      end
      local reader = require("eunoe.readers").get(s.reader)
      if not reader then
        return notify(("reader %q is no longer registered"):format(s.reader), vim.log.levels.ERROR)
      end
      local ok, err = pcall(reader.read, s.transcript, function(turns, rerr)
        if type(turns) == "table" then
          return cb(s, turns)
        end
        if tostring(rerr):find("^ENOENT") then
          return cb(s, {})
        end
        notify(("can't read %s: %s"):format(s.transcript, tostring(rerr)), vim.log.levels.ERROR)
      end)
      if not ok then
        notify(("reader %q failed: %s"):format(s.reader, tostring(err)), vim.log.levels.ERROR)
      end
    end)
  end)
end

--- Register a reader for another agent, replace one (including the
--- built-in `claude`), or remove one with `false`. See `eunoe.readers`.
---@param name string
---@param reader eunoe.Reader|false
function M.register_reader(name, reader)
  require("eunoe.readers").register(name, reader)
end

--- The turns of the current session, oldest first.
---@param opts { n: integer? }? `n`: only the last n turns.
---@param cb fun(turns: eunoe.Turn[], session: eunoe.Session)
function M.turns(opts, cb)
  opts = opts or {}
  M.load(function(s, turns)
    if opts.n and #turns > opts.n then
      turns = vim.list_slice(turns, #turns - opts.n + 1)
    end
    cb(turns, s)
  end)
end

local showing_all = false

--- Open (or refresh) the conversation split.
---@param opts { all: boolean? }?
function M.open(opts)
  opts = opts or {}
  if opts.all ~= nil then
    showing_all = opts.all
  end
  M.load(function(s, turns)
    local o = config.options
    local total = #turns
    if not showing_all and o.turns and total > o.turns then
      turns = vim.list_slice(turns, total - o.turns + 1)
    end
    local view = require("eunoe.view")
    local reader = require("eunoe.readers").get(s.reader) or {}
    local icons = o.icons
    view.show(turns, {
      name = ("eunoe://%s/%s"):format(s.reader, s.id),
      total = total,
      truncate = o.truncate,
      wrap = o.view.wrap,
      width = o.view.width,
      focus = o.view.focus,
      keys = o.keys,
      agent = type(reader.heading) == "string" and reader.heading or nil,
      speakers = {
        prompt = { hl = "EunoeUser", icon = icons and icons.user },
        reply = {
          hl = require("eunoe.highlight").agent_group(s.reader, reader.color),
          icon = icons and (icons.agent or reader.icon or view.ROBOT),
        },
      },
      handlers = {
        close = M.close,
        reload = function()
          M.open()
        end,
      },
    })
  end)
end

--- Close the conversation split.
function M.close()
  require("eunoe.view").close()
end

--- Open the split, or close it when it's open.
---@param opts { all: boolean? }?
function M.toggle(opts)
  if require("eunoe.view").current() then
    M.close()
  else
    M.open(opts or { all = false })
  end
end

return M
