--- Claude Code transcript reader.
---
--- Parses a session transcript (`~/.claude/projects/*/<sessionId>.jsonl`)
--- into turns. The format is internal to Claude Code and changes between
--- releases, so the parser keeps to a few fields and tolerates everything
--- else: unknown record types are counted, not rejected.
local M = {}

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
