--- `:checkhealth eunoe`
local M = {}

local health = vim.health

--- Process names for pids, from one `ps` call; pid → name.
---@param pids integer[]
---@return table<integer, string>
local function names(pids)
  if #pids == 0 then
    return {}
  end
  local ok, job = pcall(
    vim.system,
    { "ps", "-o", "pid=", "-o", "comm=", "-p", table.concat(pids, ",") },
    { text = true }
  )
  local res = ok and job:wait(3000)
  local out = {}
  if res and res.code == 0 and res.stdout then
    for pid, comm in res.stdout:gmatch("(%d+)%s+([^\n]+)") do
      out[tonumber(pid)] = vim.fn.fnamemodify(vim.trim(comm), ":t")
    end
  end
  return out
end

local function check_setup()
  health.start("eunoe: Neovim and configuration")
  local v = vim.version()
  local version = ("%d.%d.%d"):format(v.major, v.minor, v.patch)
  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim " .. version)
  elseif vim.fn.has("nvim-0.10") == 1 then
    health.warn("Neovim " .. version .. ": eunoe is tested with 0.11 and later")
  else
    health.error("Neovim " .. version .. ": eunoe needs 0.10 or later")
  end
  local problems = require("eunoe.config").problems
  if #problems == 0 then
    health.ok("setup() options are valid (or setup() wasn't called; it's optional)")
  else
    for _, p in ipairs(problems) do
      health.warn("setup(): " .. p)
    end
  end
end

---@return eunoe.Context
local function check_processes()
  health.start("eunoe: process lookup")
  local session = require("eunoe.session")
  local ctx = session.context_sync()
  local shown = vim.list_slice(ctx.chain, 1, 6)
  local by_pid = names(shown)
  local chain = table.concat(
    vim.tbl_map(function(pid)
      return ("%s (%d)"):format(by_pid[pid] or "?", pid)
    end, shown),
    " → "
  )
  if ctx.procs then
    health.ok(("`ps` works. Neovim's ancestors: %s"):format(chain ~= "" and chain or "none"))
  else
    health.warn(
      "`ps` isn't available or failed, so eunoe only sees Neovim's direct parent and finds most sessions by cwd",
      { "Make sure `ps` is on $PATH" }
    )
  end
  health.info("cwd: " .. ctx.cwd)
  return ctx
end

local function check_readers()
  health.start("eunoe: readers")
  local readers = require("eunoe.readers")
  local all, order = readers.all()
  if #order == 0 then
    return health.error("No readers registered", { "Don't remove the built-in `claude` reader, or register one" })
  end
  for _, name in ipairs(order) do
    local reader = all[name]
    local label = reader.label and (" · " .. reader.label) or ""
    health.ok(("%s%s (%s)"):format(name, label, readers.is_builtin(name, reader) and "built in" or "registered"))
    if vim.is_callable(reader.health) then
      local ok, err = pcall(reader.health, health)
      if not ok then
        health.error(("%s: health check failed: %s"):format(name, tostring(err)))
      end
    end
  end
end

--- Read a session's transcript with its reader, waiting for the result.
local function read_now(reader, transcript)
  local done, turns, extra = false, nil, nil
  local ok, err = pcall(reader.read, transcript, function(t, e)
    done, turns, extra = true, t, e
  end)
  if not ok then
    return nil, "reader failed: " .. tostring(err)
  end
  if not vim.wait(5000, function()
    return done
  end, 10) then
    return nil, "reading timed out"
  end
  return turns, extra
end

local function check_transcript(s)
  local reader = require("eunoe.readers").get(s.reader)
  if not s.transcript then
    return health.ok('No transcript yet (written after the first prompt): `:Eunoe` shows "No conversation yet"')
  end
  health.info("Transcript: " .. s.transcript)
  local turns, extra = read_now(reader, s.transcript)
  if type(turns) ~= "table" then
    if tostring(extra):find("^ENOENT") then
      return health.ok("No transcript yet (written after the first prompt)")
    end
    return health.error("Can't read the transcript: " .. tostring(extra))
  end
  health.ok(("%d turn(s)"):format(#turns))
  local stats = type(extra) == "table" and extra or nil
  if not stats then
    return
  end
  local advice =
    { "The agent may have changed its transcript format; eunoe may show less than it should. Please report it." }
  if stats.records and stats.records > 0 and #turns == 0 then
    health.warn(("No turns found in a transcript with %d records"):format(stats.records), advice)
  end
  if stats.invalid and stats.invalid > 0 then
    health.warn(("%d line(s) of the transcript aren't valid JSON"):format(stats.invalid), advice)
  end
  local unknown = {}
  for t, n in pairs(stats.unknown or {}) do
    unknown[#unknown + 1] = ("%s (%d)"):format(t, n)
  end
  table.sort(unknown)
  if #unknown > 0 then
    health.warn(("Records of types eunoe doesn't know: %s"):format(table.concat(unknown, ", ")), advice)
  elseif stats.unknown then
    health.ok("All record types are known")
  end
end

---@param ctx eunoe.Context
local function check_session(ctx)
  health.start("eunoe: current session")
  local found = require("eunoe.session").find(ctx)
  if #found == 0 then
    return health.info(
      "No agent session found. That's expected unless Neovim runs as the agent's editor (e.g. after Ctrl+G in Claude Code) or next to it in the same directory."
    )
  end
  if #found > 1 then
    health.info(("%d sessions run in this directory; `:Eunoe` asks which one. Checking the newest."):format(#found))
  end
  local s = found[1]
  local reader = require("eunoe.readers").get(s.reader)
  local label = reader and reader.label or s.reader
  local how = s.via == "parent" and "Neovim was started from it" or "it runs in Neovim's cwd"
  health.ok(("%s session %s, pid %d (%s)"):format(label, s.id, s.pid, how))
  if s.version then
    local tested = reader and reader.tested_version
    health.info(
      ("%s %s%s"):format(label, s.version, tested and (" (eunoe was last checked against " .. tested .. ")") or "")
    )
  end
  check_transcript(s)
end

function M.check()
  check_setup()
  local ctx = check_processes()
  check_readers()
  check_session(ctx)
end

return M
