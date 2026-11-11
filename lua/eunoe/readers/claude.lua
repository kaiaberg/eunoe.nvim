--- Claude Code transcript reader.
---
--- Parses a session transcript (`~/.claude/projects/*/<sessionId>.jsonl`)
--- into turns. The format is internal to Claude Code and changes between
--- releases, so the parser keeps to a few fields and tolerates everything
--- else: unknown record types are counted, not rejected.
local M = {}

--- The Claude Code version the parser and session lookup were last
--- checked against (`:checkhealth eunoe` shows it next to the running one).
M.tested_version = "2.1.322"

--- Display name, for messages and `:checkhealth`.
M.label = "Claude Code"

--- Name in the reply headings (`# 6 · Claude`), its icon (nf-cod-claude)
--- and color (Claude's terracotta, for `EunoeAgentClaude`).
M.heading = "Claude"
M.icon = "\u{ec82}"
M.color = "#D97757"

---@class eunoe.Turn
---@field n integer Turn number, starting at 1.
---@field prompt string? The user's prompt; nil when a reply has no prompt (e.g. the first one after compaction).
---@field reply string? The agent's reply text (tool calls and thinking left out).
---@field time string? ISO timestamp of the prompt (or of the reply, without a prompt).
---@field command boolean? The prompt is a slash command, rendered as `/name args`.
---@field interrupted boolean? The user interrupted the reply.

---@class eunoe.ParseStats
---@field records integer Lines that decoded to a JSON object.
---@field invalid integer Lines that didn't decode.
---@field unknown table<string, integer> Records of types the parser doesn't know, by type.

-- Record types seen in Claude Code 2.1.x transcripts. Only `user`,
-- `assistant`, `attachment` and `system` matter for turns (the last two
-- only as links in the `parentUuid` chain); the rest is listed so that new
-- types stand out in the stats.
local KNOWN_TYPES = {}
for _, t in ipairs({
  "user",
  "assistant",
  "attachment",
  "system",
  "summary",
  "api-request",
  "api-request-blob",
  "api-request-shape",
  "last-prompt",
  "atis-latch",
  "mode",
  "permission-mode",
  "session-owner",
  "ai-title",
  "custom-title",
  "agent-name",
  "file-history-snapshot",
  "file-history-delta",
  "tools-used",
  "cost-state",
  "queue-operation",
  "artifact-autoreact-ledger",
  "artifact-comment-monitor",
  "frame-link",
  "continued-in",
}) do
  KNOWN_TYPES[t] = true
end

-- Tags Claude Code wraps around user records that aren't prompts: output of
-- `!` commands and local slash commands, injected reminders and background
-- task notifications.
local INJECTED_TAGS = {
  ["bash-input"] = true,
  ["bash-stdout"] = true,
  ["bash-stderr"] = true,
  ["local-command-stdout"] = true,
  ["local-command-stderr"] = true,
  ["local-command-caveat"] = true,
  ["system-reminder"] = true,
  ["task-notification"] = true,
  ["user-prompt-submit-hook"] = true,
}

local DECODE_OPTS = { luanil = { object = true, array = true } }

--- The text of a user record's content, or nil when it holds tool results
--- or no text at all.
---@return string?
local function user_text(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return nil
  end
  local parts = {}
  for _, block in ipairs(content) do
    if type(block) == "table" then
      if block.type == "tool_result" then
        return nil
      elseif block.type == "text" and type(block.text) == "string" then
        parts[#parts + 1] = block.text
      end
    end
  end
  return #parts > 0 and table.concat(parts, "\n") or nil
end

--- Classify a user record: "prompt", "command", "interrupt" or nil (skip).
---@return string? kind
---@return string? text
local function classify_user(rec)
  if rec.isMeta or rec.isCompactSummary or rec.isSidechain then
    return nil
  end
  local text = user_text(rec.message and rec.message.content)
  if not text then
    return nil
  end
  if text:find("^%[Request interrupted by user") then
    return "interrupt"
  end
  local lead = text:match("^%s*<([%w-]+)>")
  if lead == "command-name" or lead == "command-message" then
    local name = text:match("<command%-name>%s*(.-)%s*</command%-name>")
    if not name or name == "" then
      return nil
    end
    if name:sub(1, 1) ~= "/" then
      name = "/" .. name
    end
    local args = text:match("<command%-args>%s*(.-)%s*</command%-args>")
    return "command", (args and args ~= "") and (name .. " " .. args) or name
  end
  if lead and INJECTED_TAGS[lead] then
    return nil
  end
  return "prompt", text
end

--- The text blocks of an assistant record, joined; nil without text.
---@return string?
local function assistant_text(rec)
  local content = rec.message and rec.message.content
  if type(content) == "string" then
    return content ~= "" and content or nil
  end
  if type(content) ~= "table" then
    return nil
  end
  local parts = {}
  for _, block in ipairs(content) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" and block.text ~= "" then
      parts[#parts + 1] = block.text
    end
  end
  return #parts > 0 and table.concat(parts, "\n\n") or nil
end

--- Decode the records and walk the active branch back from the newest
--- user or assistant record, following `parentUuid` and, at a `/compact`
--- boundary, `logicalParentUuid`. Rewound branches are left out.
---@return table[] chain Records from the oldest to the newest.
---@return eunoe.ParseStats
local function active_chain(lines)
  local stats = { records = 0, invalid = 0, unknown = {} }
  local by_uuid, leaf = {}, nil
  for _, line in ipairs(lines) do
    if line:find("%S") then
      local ok, rec = pcall(vim.json.decode, line, DECODE_OPTS)
      if ok and type(rec) == "table" then
        stats.records = stats.records + 1
        local t = rec.type
        if type(t) == "string" and not KNOWN_TYPES[t] then
          stats.unknown[t] = (stats.unknown[t] or 0) + 1
        end
        if type(rec.uuid) == "string" then
          by_uuid[rec.uuid] = rec
          if (t == "user" or t == "assistant") and not rec.isSidechain then
            leaf = rec
          end
        end
      else
        stats.invalid = stats.invalid + 1
      end
    end
  end

  local chain, seen = {}, {}
  local rec = leaf
  while rec and not seen[rec] do
    seen[rec] = true
    chain[#chain + 1] = rec
    local parent = rec.parentUuid or rec.logicalParentUuid
    rec = type(parent) == "string" and by_uuid[parent] or nil
  end
  -- Reverse into oldest-first order.
  for i = 1, math.floor(#chain / 2) do
    chain[i], chain[#chain - i + 1] = chain[#chain - i + 1], chain[i]
  end
  return chain, stats
end

--- Parse a transcript into turns.
---@param input string|string[] The file's contents, or its lines.
---@return eunoe.Turn[] turns Oldest first.
---@return eunoe.ParseStats stats
function M.parse(input)
  local lines = type(input) == "string" and vim.split(input, "\n", { plain = true }) or input
  local chain, stats = active_chain(lines)

  local turns, cur = {}, nil
  local function start(kind, text, rec)
    cur = { prompt = text, time = rec.timestamp, command = kind == "command" or nil, parts = {} }
    turns[#turns + 1] = cur
  end
  for _, rec in ipairs(chain) do
    if rec.type == "user" then
      local kind, text = classify_user(rec)
      if kind == "prompt" or kind == "command" then
        start(kind, text, rec)
      elseif kind == "interrupt" and cur then
        cur.interrupted = true
      end
    elseif rec.type == "assistant" and not rec.isSidechain then
      local text = assistant_text(rec)
      if text then
        if not cur then
          start(nil, nil, rec)
        end
        cur.parts[#cur.parts + 1] = text
      end
    end
  end

  -- A command without a reply (`/clear`, `/model`, …) ran locally; it isn't
  -- part of the conversation.
  local out = {}
  for _, t in ipairs(turns) do
    local reply = #t.parts > 0 and table.concat(t.parts, "\n\n") or nil
    if not (t.command and not reply) then
      out[#out + 1] = {
        n = #out + 1,
        prompt = t.prompt,
        reply = reply,
        time = t.time,
        command = t.command,
        interrupted = t.interrupted,
      }
    end
  end
  return out, stats
end

--- Claude Code's config directory: `$CLAUDE_CONFIG_DIR` or `~/.claude`.
---@return string
function M.root()
  local dir = vim.env.CLAUDE_CONFIG_DIR
  if not dir or dir == "" then
    dir = (vim.env.HOME or vim.fn.expand("~")) .. "/.claude"
  end
  return vim.fs.normalize(dir)
end

---@return table?
local function read_json(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  local ok, obj = pcall(vim.json.decode, data, DECODE_OPTS)
  return ok and type(obj) == "table" and obj or nil
end

--- The transcript of a session id, or nil (none before the first prompt).
--- Globs on the id, which avoids Claude Code's project-folder naming rule.
---@param id string
---@return string?
function M.transcript(id)
  if not id:match("^[%w%-]+$") then
    return nil
  end
  local found = vim.fn.glob(M.root() .. "/projects/*/" .. id .. ".jsonl", true, true)
  return found[1]
end

--- A sessions file (`<root>/sessions/<pid>.json`) as a session, when it is
--- well-formed and its process is still the one that wrote it.
---@param ctx eunoe.Context
---@param info table?
---@param pid integer
---@param via "parent"|"cwd"
---@return eunoe.Session?
local function session_of(ctx, info, pid, via)
  if not info or info.pid ~= pid or type(info.sessionId) ~= "string" or type(info.cwd) ~= "string" then
    return nil
  end
  local start = type(info.procStart) == "string" and info.procStart or nil
  if not require("eunoe.session").alive(ctx, pid, start) then
    return nil
  end
  return {
    reader = "claude",
    id = info.sessionId,
    pid = pid,
    cwd = info.cwd,
    transcript = M.transcript(info.sessionId),
    via = via,
    name = type(info.name) == "string" and info.name or nil,
    updated = type(info.updatedAt) == "number" and info.updatedAt or nil,
    version = type(info.version) == "string" and info.version or nil,
  }
end

--- Find Claude Code sessions for a context. Claude Code keeps a file per
--- running process in `<root>/sessions/<pid>.json` with the current
--- `sessionId` (it follows `/clear` and `/resume`). The nearest ancestor
--- with such a file is the session Neovim was started from; without one,
--- return the live sessions whose cwd is Neovim's.
---@param ctx eunoe.Context
---@return eunoe.Session[]
function M.detect(ctx)
  local dir = M.root() .. "/sessions"
  for _, pid in ipairs(ctx.chain) do
    local s = session_of(ctx, read_json(("%s/%d.json"):format(dir, pid)), pid, "parent")
    if s then
      return { s }
    end
  end
  local realpath = require("eunoe.session").realpath
  local found = {}
  for name, kind in vim.fs.dir(dir) do
    local pid = kind == "file" and tonumber(name:match("^(%d+)%.json$"))
    if pid then
      local info = read_json(dir .. "/" .. name)
      if info and type(info.cwd) == "string" and realpath(info.cwd) == ctx.cwd then
        found[#found + 1] = session_of(ctx, info, pid, "cwd")
      end
    end
  end
  return found
end

--- Checks for `:checkhealth eunoe`: where Claude Code keeps its files.
---@param health table `vim.health`
function M.health(health)
  local root = M.root()
  local from_env = vim.env.CLAUDE_CONFIG_DIR and vim.env.CLAUDE_CONFIG_DIR ~= ""
  local where = from_env and "(from $CLAUDE_CONFIG_DIR)" or "(set $CLAUDE_CONFIG_DIR to use another one)"
  if vim.fn.isdirectory(root) == 0 then
    return health.warn(("Claude Code config directory %s doesn't exist %s"):format(root, where))
  end
  health.ok(("Claude Code config directory: %s %s"):format(root, where))
  local dir = root .. "/sessions"
  if vim.fn.isdirectory(dir) == 0 then
    return health.warn(("%s doesn't exist: Claude Code hasn't run yet, or is older than eunoe supports"):format(dir))
  end
  local files = vim.fn.glob(dir .. "/*.json", true, true)
  health.ok(("%d sessions file(s) in %s (Claude Code writes one per process)"):format(#files, dir))
end

--- Read and parse a transcript file asynchronously.
---
--- Calls `cb(turns, stats)` on success, or `cb(nil, err)` when the file
--- can't be read; a missing file gives `err` starting with "ENOENT"
--- (Claude Code writes the transcript only after the first prompt).
--- The callback runs on the main loop.
---@param path string
---@param cb fun(turns: eunoe.Turn[]?, stats_or_err: eunoe.ParseStats|string)
function M.read(path, cb)
  local done = vim.schedule_wrap(cb)
  vim.uv.fs_open(path, "r", 438, function(err, fd)
    if err or not fd then
      return done(nil, err or "cannot open " .. path)
    end
    vim.uv.fs_fstat(fd, function(serr, stat)
      if serr or not stat then
        vim.uv.fs_close(fd)
        return done(nil, serr or "cannot stat " .. path)
      end
      vim.uv.fs_read(fd, stat.size, 0, function(rerr, data)
        vim.uv.fs_close(fd)
        if rerr or not data then
          return done(nil, rerr or "cannot read " .. path)
        end
        vim.schedule(function()
          local ok, turns, stats = pcall(M.parse, data)
          if ok then
            cb(turns, stats)
          else
            cb(nil, "parse error: " .. tostring(turns))
          end
        end)
      end)
    end)
  end)
end

return M
