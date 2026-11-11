--- Find the agent session(s) this Neovim belongs to.
---
--- Builds a context (this process's ancestors and the cwd) and asks each
--- reader's `detect(ctx)` for sessions. A session found among the
--- ancestors is the one Neovim was started from (e.g. `Ctrl+G` in Claude
--- Code) and wins; otherwise readers match sessions by cwd (side panel).
local M = {}

---@class eunoe.Process
---@field ppid integer
---@field start string? Start time as `ps -o lstart=` prints it in UTC, whitespace collapsed.

---@class eunoe.Context
---@field pid integer This Neovim's pid.
---@field chain integer[] Ancestors of `pid`, nearest first (without `pid` itself).
---@field cwd string Neovim's cwd, resolved (symlinks, `/tmp` → `/private/tmp`).
---@field procs table<integer, eunoe.Process>? Process table; nil where `ps` isn't available.

---@class eunoe.Session
---@field reader string Name of the reader that found it, e.g. "claude".
---@field id string The agent's session id.
---@field pid integer The agent's process.
---@field cwd string The agent's cwd.
---@field transcript string? Path of the transcript; nil before the first prompt.
---@field via "parent"|"cwd" How it was found.
---@field name string? Display name, if the agent has one.
---@field updated integer? Last update in ms since the epoch, for sorting.

--- Parse `ps -A -o pid= -o ppid= -o lstart=` output.
---@param out string
---@return table<integer, eunoe.Process>
function M.parse_ps(out)
  local procs = {}
  for line in out:gmatch("[^\n]+") do
    local pid, ppid, start = line:match("^%s*(%d+)%s+(%d+)%s*(.-)%s*$")
    if pid then
      procs[tonumber(pid)] = { ppid = tonumber(ppid), start = start ~= "" and start:gsub("%s+", " ") or nil }
    end
  end
  return procs
end

--- Ancestors of `pid`, nearest first, from a process table.
---@param procs table<integer, eunoe.Process>
---@param pid integer
---@return integer[]
function M.ancestors(procs, pid)
  local chain, seen = {}, { [pid] = true }
  local p = procs[pid] and procs[pid].ppid
  while p and p > 1 and not seen[p] do
    seen[p] = true
    chain[#chain + 1] = p
    p = procs[p] and procs[p].ppid
  end
  return chain
end

--- Resolve a path's symlinks; the path itself if that fails.
---@param path string
---@return string
function M.realpath(path)
  return vim.uv.fs_realpath(path) or path
end

--- Build the context asynchronously. Runs `ps` once (in UTC, so start
--- times compare with what agents record); without `ps` the chain holds
--- only the direct parent and `procs` is nil.
---@param cb fun(ctx: eunoe.Context)
function M.context(cb)
  local pid = vim.fn.getpid()
  local cwd = M.realpath(vim.fn.getcwd())
  local function fallback()
    local ppid = vim.uv.os_getppid()
    cb({ pid = pid, chain = ppid and ppid > 1 and { ppid } or {}, cwd = cwd })
  end
  local ok = pcall(
    vim.system,
    { "ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "lstart=" },
    { text = true, env = { TZ = "UTC" } },
    vim.schedule_wrap(function(res)
      if res.code ~= 0 or not res.stdout then
        return fallback()
      end
      local procs = M.parse_ps(res.stdout)
      if not procs[pid] then
        return fallback()
      end
      cb({ pid = pid, chain = M.ancestors(procs, pid), cwd = cwd, procs = procs })
    end)
  )
  if not ok then
    fallback()
  end
end

--- Whether `pid` is alive and, when both start times are known, the same
--- process that started at `start` (guards against pid reuse after a
--- crash left a stale sessions file).
---@param ctx eunoe.Context
---@param pid integer
---@param start string?
---@return boolean
function M.alive(ctx, pid, start)
  if ctx.procs then
    local p = ctx.procs[pid]
    if not p then
      return false
    end
    if start and p.start then
      return p.start == start:gsub("%s+", " ")
    end
    return true
  end
  return vim.uv.kill(pid, 0) == 0
end

--- The registered readers, in detection order.
---@return table<string, eunoe.Reader>, string[]
function M.readers()
  return require("eunoe.readers").all()
end

--- Whether a reader's result looks like a session.
local function valid(s)
  return type(s) == "table"
    and type(s.id) == "string"
    and type(s.pid) == "number"
    and (s.via == "parent" or s.via == "cwd")
    and (s.transcript == nil or type(s.transcript) == "string")
end

--- Sessions for a context: the one among Neovim's ancestors if any reader
--- finds one (nearest ancestor wins), else all sessions matched by cwd,
--- newest first.
---@param ctx eunoe.Context
---@param readers table<string, eunoe.Reader>? Name → reader; defaults to the registered ones.
---@param order string[]? Reader names in detection order.
---@return eunoe.Session[]
function M.find(ctx, readers, order)
  if not readers then
    readers, order = M.readers()
  end
  order = order or vim.tbl_keys(readers)
  local by_cwd = {}
  local best, best_depth
  for _, name in ipairs(order) do
    local reader = readers[name]
    local ok, found = pcall(reader.detect, ctx)
    if ok and type(found) == "table" then
      for _, s in ipairs(found) do
        if valid(s) then
          s.reader = name
          -- Nearest ancestor wins: the index of its pid in the chain. A
          -- "parent" session whose pid isn't an ancestor counts as by cwd.
          local depth
          if s.via == "parent" then
            for i, p in ipairs(ctx.chain) do
              if p == s.pid then
                depth = i
                break
              end
            end
          end
          if depth then
            if not best or depth < best_depth then
              best, best_depth = s, depth
            end
          else
            s.via = "cwd"
            by_cwd[#by_cwd + 1] = s
          end
        end
      end
    end
  end
  if best then
    return { best }
  end
  table.sort(by_cwd, function(a, b)
    return (a.updated or 0) > (b.updated or 0)
  end)
  return by_cwd
end

--- Find sessions for this Neovim asynchronously.
---@param cb fun(sessions: eunoe.Session[], ctx: eunoe.Context)
function M.lookup(cb)
  M.context(function(ctx)
    cb(M.find(ctx), ctx)
  end)
end

return M
