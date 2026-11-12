local h = require("helpers")
local session = require("eunoe.session")
local claude = require("eunoe.readers.claude")

local START = "Wed Nov 11 08:27:45 2026"

--- A fake Claude config dir with sessions files and transcripts.
--- `files` maps pid → sessions-file table (or a raw string);
--- `transcripts` lists session ids that have a transcript.
local function fake_root(files, transcripts)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/sessions", "p")
  vim.fn.mkdir(root .. "/projects/-some-project", "p")
  for pid, info in pairs(files) do
    local data = type(info) == "string" and info or vim.json.encode(info)
    vim.fn.writefile({ data }, ("%s/sessions/%d.json"):format(root, pid))
  end
  for _, id in ipairs(transcripts or {}) do
    vim.fn.writefile({}, root .. "/projects/-some-project/" .. id .. ".jsonl")
  end
  return root
end

--- Run `fn` with CLAUDE_CONFIG_DIR pointing at `root`.
local function with_root(root, fn)
  local old = vim.env.CLAUDE_CONFIG_DIR
  vim.env.CLAUDE_CONFIG_DIR = root
  local ok, err = pcall(fn)
  vim.env.CLAUDE_CONFIG_DIR = old
  if not ok then
    error(err, 0)
  end
end

local function info(pid, id, cwd, extra)
  return vim.tbl_extend("force", { pid = pid, sessionId = id, cwd = cwd, procStart = START }, extra or {})
end

--- A context: Neovim (pid 10) under the given chain of ancestors, all
--- alive with START as their start time.
local function ctx(chain, cwd, procs)
  procs = procs or {}
  local all = { 10, unpack(chain) }
  for i, pid in ipairs(all) do
    procs[pid] = procs[pid] or { ppid = all[i + 1] or 1, start = START }
  end
  return { pid = 10, chain = chain, cwd = cwd or "/work", procs = procs }
end

local function ids(sessions)
  return vim.tbl_map(function(s)
    return s.id
  end, sessions)
end

return {
  ["parse_ps: pids, parents and start times with collapsed whitespace"] = function()
    local procs =
      session.parse_ps("    1     0 Sun Nov  8 22:10:44 2026    \n  352     1 Sun Nov  8 22:11:13 2026\n  bad line\n")
    h.eq(procs, {
      [1] = { ppid = 0, start = "Sun Nov 8 22:10:44 2026" },
      [352] = { ppid = 1, start = "Sun Nov 8 22:11:13 2026" },
    })
  end,
  ["ancestors: nearest first, stops at pid 1 and on cycles"] = function()
    h.eq(session.ancestors({ [10] = { ppid = 20 }, [20] = { ppid = 30 }, [30] = { ppid = 1 } }, 10), { 20, 30 })
    h.eq(session.ancestors({ [10] = { ppid = 20 }, [20] = { ppid = 10 } }, 10), { 20 })
    h.eq(session.ancestors({}, 10), {})
  end,
  ["alive: same pid and start time; whitespace doesn't matter"] = function()
    local c = { procs = { [5] = { ppid = 1, start = "Sun Nov 8 22:10:44 2026" } } }
    h.eq(session.alive(c, 5, "Sun Nov  8 22:10:44 2026"), true)
    h.eq(session.alive(c, 5, "Mon Nov 9 09:00:00 2026"), false, "reused pid")
    h.eq(session.alive(c, 5, nil), true, "no start time recorded")
    h.eq(session.alive(c, 6, nil), false, "dead pid")
  end,
  ["parse_stat: field 22, also with spaces and parentheses in the name"] = function()
    local tail = " S 1 1183950 1183950 34816 1183954 4194560 51244 0 4 0 2100 380 0 0 20 0 11 0 241398901 1234 5678"
    h.eq(session.parse_stat("1183954 (claude)" .. tail), "241398901")
    h.eq(session.parse_stat("1183954 (my (odd) name)" .. tail), "241398901")
    h.eq(session.parse_stat("1183954 (claude) S 1 2"), nil, "too short")
    h.eq(session.parse_stat("garbage"), nil)
  end,
  ["alive: clock ticks (Linux) are compared with /proc, or ignored without it"] = function()
    local real = session.proc_start
    local ok, err = pcall(function()
      local c = { procs = { [5] = { ppid = 1, start = "Thu Nov 12 08:15:42 2026" } } }
      session.proc_start = function(pid)
        return pid == 5 and "241398901" or nil
      end
      h.eq(session.alive(c, 5, "241398901"), true, "ticks as a string")
      h.eq(session.alive(c, 5, 241398901), true, "ticks as a number")
      h.eq(session.alive(c, 5, "241399999"), false, "reused pid")
      h.eq(session.alive(c, 5, "Thu Nov 12 08:15:42 2026"), true, "a date still compares with ps")
      session.proc_start = function()
        return nil
      end
      h.eq(session.alive(c, 5, "241398901"), true, "no /proc: the pid is enough")
      h.eq(session.alive(c, 6, "241398901"), false, "no /proc, dead pid")
    end)
    session.proc_start = real
    if not ok then
      error(err, 0)
    end
  end,
  ["proc_start: this Neovim's start time where /proc exists"] = function()
    local ticks = session.proc_start(vim.fn.getpid())
    if vim.uv.fs_stat("/proc/self/stat") then
      h.truthy(ticks and ticks:match("^%d+$"), "got " .. tostring(ticks))
    else
      h.eq(ticks, nil)
    end
  end,
  ["context: real process table, chain starts at the parent"] = function()
    local got
    session.context(function(c)
      got = c
    end)
    h.wait(function()
      return got ~= nil
    end)
    h.eq(got.pid, vim.fn.getpid())
    h.eq(got.chain[1], vim.uv.os_getppid())
    h.truthy(got.procs and got.procs[got.pid], "ps should list this process")
    h.truthy(got.procs[got.pid].start, "ps should give a start time")
  end,
  ["detect: the nearest ancestor with a sessions file"] = function()
    local root = fake_root({
      [20] = info(20, "near", "/elsewhere"),
      [30] = info(30, "far", "/work"),
    }, { "near" })
    with_root(root, function()
      local found = claude.detect(ctx({ 20, 30 }))
      h.eq(#found, 1)
      h.eq(found[1].id, "near")
      h.eq(found[1].via, "parent")
      h.eq(found[1].pid, 20)
      h.eq(found[1].transcript, root .. "/projects/-some-project/near.jsonl")
    end)
  end,
  ["detect: no transcript before the first prompt"] = function()
    with_root(fake_root({ [20] = info(20, "fresh", "/work") }), function()
      local found = claude.detect(ctx({ 20 }))
      h.eq(found[1].id, "fresh")
      h.eq(found[1].transcript, nil)
    end)
  end,
  ["detect: skips a stale file whose pid was reused"] = function()
    local root = fake_root({
      [20] = info(20, "stale", "/work"),
      [30] = info(30, "real", "/work"),
    })
    with_root(root, function()
      local c = ctx({ 20, 30 }, "/work", { [20] = { ppid = 30, start = "Thu Nov 12 07:00:00 2026" } })
      h.eq(ids(claude.detect(c)), { "real" })
    end)
  end,
  ["detect: Linux, where procStart is clock ticks and ps prints dates"] = function()
    local real = session.proc_start
    session.proc_start = function(pid)
      return pid == 20 and "241398901" or nil
    end
    local root = fake_root({ [20] = info(20, "linux", "/work", { procStart = "241398901" }) }, { "linux" })
    local ok, err = pcall(with_root, root, function()
      local found = claude.detect(ctx({ 20 }))
      h.eq(ids(found), { "linux" })
      h.eq(found[1].via, "parent")
    end)
    session.proc_start = real
    if not ok then
      error(err, 0)
    end
  end,
  ["detect: by cwd when no ancestor has a sessions file"] = function()
    local root = fake_root({
      [40] = info(40, "old", "/work", { updatedAt = 1 }),
      [50] = info(50, "new", "/work", { updatedAt = 2 }),
      [60] = info(60, "other", "/other"),
      [70] = info(70, "dead", "/work"),
      [80] = "{ not json",
    })
    with_root(root, function()
      local c = ctx({ 20 }, "/work", {
        [40] = { ppid = 1, start = START },
        [50] = { ppid = 1, start = START },
        [60] = { ppid = 1, start = START },
      })
      local found = session.find(c)
      h.eq(ids(found), { "new", "old" })
      h.eq(found[1].via, "cwd")
      h.eq(found[1].reader, "claude")
    end)
  end,
  ["detect: cwd matches through symlinks"] = function()
    local real = vim.fn.tempname()
    vim.fn.mkdir(real, "p")
    real = vim.uv.fs_realpath(real)
    local link = vim.fn.tempname()
    vim.uv.fs_symlink(real, link)
    with_root(fake_root({ [40] = info(40, "linked", link) }), function()
      h.eq(ids(claude.detect(ctx({ 20 }, real, { [40] = { ppid = 1, start = START } }))), { "linked" })
    end)
  end,
  ["detect: missing sessions dir and odd ids are harmless"] = function()
    with_root(vim.fn.tempname(), function()
      h.eq(claude.detect(ctx({ 20 })), {})
    end)
    h.eq(claude.transcript("../*"), nil)
  end,
  ["find: a parent session beats cwd matches from any reader"] = function()
    local readers = {
      a = {
        detect = function()
          return { { id = "by-cwd", via = "cwd", pid = 99 } }
        end,
      },
      b = {
        detect = function()
          return { { id = "far-parent", via = "parent", pid = 30 } }
        end,
      },
      c = {
        detect = function()
          return { { id = "near-parent", via = "parent", pid = 20 } }
        end,
      },
      broken = {
        detect = function()
          error("boom")
        end,
      },
    }
    local found = session.find(ctx({ 20, 30 }), readers, { "a", "broken", "b", "c" })
    h.eq(ids(found), { "near-parent" })
    h.eq(found[1].reader, "c")
  end,
}
