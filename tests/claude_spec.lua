local h = require("helpers")
local claude = require("eunoe.readers.claude")

local function parse(name)
  return claude.parse(h.lines("claude/" .. name))
end

--- Turns as { prompt, reply } pairs, for compact comparisons.
local function pairs_of(turns)
  return vim.tbl_map(function(t)
    return { t.prompt, t.reply }
  end, turns)
end

return {
  ["plain: replies join text blocks, skip thinking, tool calls and results"] = function()
    local turns = parse("plain.jsonl")
    h.eq(pairs_of(turns), {
      { "Explain the parser.", "Let me look at it.\n\nIt walks the chain." },
      { "Thanks!\nTwo lines.", "You're welcome." },
    })
    h.eq(turns[1].n, 1)
    h.eq(turns[2].n, 2)
    h.eq(turns[1].time, "2026-11-11T10:00:00.000Z")
  end,
  ["plain: tool output never reaches a turn"] = function()
    for _, t in ipairs(parse("plain.jsonl")) do
      h.truthy(not (t.prompt or ""):find("secret") and not (t.reply or ""):find("secret"), "tool output leaked")
    end
  end,
  ["plain: stats count records, invalid lines and unknown types"] = function()
    local _, stats = parse("plain.jsonl")
    h.eq(stats, { records = 13, invalid = 1, unknown = { ["brand-new-record"] = 1 } })
  end,
  ["rewound: only the active branch"] = function()
    h.eq(pairs_of(parse("rewound.jsonl")), {
      { "First prompt", "First reply" },
      { "Prompt after rewind", "Reply after rewind" },
    })
  end,
  ["compacted: follows logicalParentUuid, skips the summary"] = function()
    h.eq(pairs_of(parse("compacted.jsonl")), {
      { "Before compaction", "Old reply" },
      { "After compaction", "New reply" },
    })
  end,
  ["injected: commands, ! output, reminders, images, interrupts"] = function()
    local turns = parse("injected.jsonl")
    h.eq(pairs_of(turns), {
      { "/handoff resume", "Resuming from the handoff." },
      { "[Image #1] What's in this image?", "A cat." },
      { "Write a long essay", "Once upon" },
      { "<div> is not a tag Claude Code adds", "Right." },
    })
    h.eq(turns[1].command, true)
    h.eq(turns[2].command, nil)
    h.eq(turns[3].interrupted, true)
    h.eq(turns[4].interrupted, nil)
  end,
  ["after /clear: the /clear record is not a turn"] = function()
    h.eq(pairs_of(parse("after-clear.jsonl")), { { "say bye", "Bye! 👋" } })
  end,
  ["resumed: turns before and after /resume, in order"] = function()
    local turns, stats = parse("resumed.jsonl")
    h.eq(pairs_of(turns), {
      { "say hi", "Hi! What would you like to work on?" },
      { "say hi again", "Hi again!" },
    })
    h.eq(stats.unknown, {})
    h.eq(stats.invalid, 0)
  end,
  ["parse accepts a string and blank lines"] = function()
    local text = table.concat(h.lines("claude/rewound.jsonl"), "\n") .. "\n\n"
    local turns, stats = claude.parse(text)
    h.eq(#turns, 2)
    h.eq(stats.invalid, 0)
  end,
  ["empty transcript: no turns"] = function()
    local turns, stats = claude.parse({})
    h.eq(turns, {})
    h.eq(stats, { records = 0, invalid = 0, unknown = {} })
  end,
  ["a reply without a prompt starts its own turn"] = function()
    local turns = claude.parse({
      '{"type":"assistant","uuid":"r1","parentUuid":null,"message":{"content":[{"type":"text","text":"Orphan"}]}}',
    })
    h.eq(pairs_of(turns), { { nil, "Orphan" } })
  end,
  ["a parentUuid cycle doesn't hang"] = function()
    local turns = claude.parse({
      '{"type":"user","uuid":"a","parentUuid":"b","message":{"content":"A"}}',
      '{"type":"assistant","uuid":"b","parentUuid":"a","message":{"content":[{"type":"text","text":"B"}]}}',
    })
    h.eq(pairs_of(turns), { { "A", "B" } })
  end,
  ["read: parses a file asynchronously"] = function()
    local got
    claude.read(h.fixture("claude/resumed.jsonl"), function(turns, stats)
      got = { turns = turns, stats = stats }
    end)
    h.wait(function()
      return got ~= nil
    end)
    h.eq(#got.turns, 2)
    h.eq(got.stats.invalid, 0)
  end,
  ["read: a missing file reports ENOENT"] = function()
    local got
    claude.read(h.fixture("claude/does-not-exist.jsonl"), function(turns, err)
      got = { turns = turns, err = err }
    end)
    h.wait(function()
      return got ~= nil
    end)
    h.eq(got.turns, nil)
    h.truthy(tostring(got.err):find("^ENOENT"), "expected ENOENT, got " .. tostring(got.err))
  end,
}
