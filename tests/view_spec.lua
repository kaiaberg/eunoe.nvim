local h = require("helpers")
local view = require("eunoe.view")

local function lines_of(text)
  return vim.split(text, "\n", { plain = true })
end

local function long(n, prefix)
  local out = {}
  for i = 1, n do
    out[i] = (prefix or "line ") .. i .. " " .. string.rep("x", 40)
  end
  return out
end

--- Close every window but one and wipe eunoe buffers.
local function reset()
  vim.cmd("silent! only")
  vim.cmd("enew")
  for buf in pairs(view.state) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  view.state = {}
end

local function show(turns, extra)
  return view.show(
    turns,
    vim.tbl_extend("force", {
      name = "eunoe://test/" .. tostring(math.random(1e9)),
      truncate = { chars = 100, open_latest = true },
      width = 60,
      focus = true,
      handlers = { close = view.close, reload = function() end },
    }, extra or {})
  )
end

local TURNS = {
  { n = 1, prompt = "First?", reply = table.concat(long(10, "a"), "\n") },
  { n = 2, prompt = table.concat(long(6, "p"), "\n"), reply = table.concat(long(10, "b"), "\n") },
}

return {
  ["cut: short text isn't folded"] = function()
    h.eq(view.cut({ "short", "text" }, 100), nil)
  end,
  ["cut: at the end of the line that crosses the limit"] = function()
    h.eq(view.cut(long(10), 100), 3) -- each line is 47 chars + newline: 48, 96, 144 > 100
  end,
  ["cut: moves before a fence that crosses the limit"] = function()
    local l = { "intro", "```lua", string.rep("x", 200), "```", "after" }
    h.eq(view.cut(l, 50), 1)
  end,
  ["cut: keeps a leading fence whole"] = function()
    local l = { "```", string.rep("x", 200), "more", "```", "after" }
    h.eq(view.cut(l, 50), 4)
    h.eq(view.cut({ "```", string.rep("x", 200), "unclosed" }, 50), nil)
  end,
  ["cut: nothing to fold when only blank lines remain"] = function()
    h.eq(view.cut({ string.rep("x", 200), "", "  " }, 50), nil)
  end,
  ["wrap: breaks long lines at spaces"] = function()
    h.eq(view.wrap({ "one two three four five", "short" }, 10), { "one two", "three four", "five", "short" })
  end,
  ["wrap: list items indent their continuation, quotes repeat >"] = function()
    h.eq(view.wrap({ "- alpha beta gamma delta" }, 12), { "- alpha beta", "  gamma", "  delta" })
    h.eq(view.wrap({ "  12. alpha beta gamma" }, 14), { "  12. alpha", "      beta", "      gamma" })
    h.eq(view.wrap({ "> alpha beta gamma" }, 10), { "> alpha", "> beta", "> gamma" })
  end,
  ["wrap: leaves code blocks, tables and long words alone"] = function()
    local code = { "```", "local x = 'a very long line of code that must not be broken'", "```" }
    h.eq(view.wrap(code, 10), code)
    h.eq(view.wrap({ "| a long | table row |" }, 5), { "| a long | table row |" })
    h.eq(view.wrap({ "see https://example.com/a/very/long/url" }, 10), { "see", "https://example.com/a/very/long/url" })
  end,
  ["wrap: width counts display cells, not bytes"] = function()
    h.eq(view.wrap({ "äöü äöü äöü" }, 7), { "äöü äöü", "äöü" })
  end,
  ["render: wrapped paragraphs can be truncated; sections keep the original text"] = function()
    local para = string.rep("word ", 100) -- one 500-character line
    local r = view.render({ { n = 1, prompt = "x", reply = para } }, { truncate = { chars = 100 }, wrap = 40 })
    h.eq(#r.folds, 1)
    h.eq(r.sections[2].text, para)
    for _, l in ipairs(r.lines) do
      h.truthy(#l <= 40, "line too long: " .. l)
    end
    local plain = view.render({ { n = 1, prompt = "x", reply = para } }, { truncate = { chars = 100 } })
    h.eq(#plain.folds, 0, "one long line can't be folded without wrapping")
  end,
  ["render: headings, blank lines, no fold without truncation"] = function()
    local r = view.render({ { n = 1, prompt = "Hi", reply = "Hello\nthere" } }, { truncate = false })
    h.eq(r.lines, { "# 1 · You", "", "Hi", "", "# 1 · Agent", "", "Hello", "there" })
    h.eq(r.headings, { { line = 1, turn = 1, role = "prompt" }, { line = 5, turn = 1, role = "reply" } })
    h.eq(r.folds, {})
    h.eq(r.sections[2], { turn = 1, role = "reply", first = 7, last = 8, text = "Hello\nthere" })
  end,
  ["render: note when older turns are left out"] = function()
    local r = view.render({ { n = 9, prompt = "Hi", reply = "Yo" } }, { truncate = false, total = 9 })
    h.eq(r.lines[1], "_The last 1 of 9 turns. `:Eunoe all` shows all of them._")
    h.eq(r.headings[1].line, 3)
  end,
  ["render: no prompt, no reply, interrupted, empty"] = function()
    local r = view.render(
      { { n = 1, reply = "Orphan" }, { n = 2, prompt = "Go", interrupted = true } },
      { truncate = false }
    )
    h.eq(r.lines, {
      "# 1 · Agent",
      "",
      "Orphan",
      "",
      "# 2 · You",
      "",
      "Go",
      "",
      "# 2 · Agent",
      "",
      "_(no reply)_",
      "",
      "_(interrupted)_",
    })
    h.eq(view.render({}, { truncate = false }).lines, { "_No conversation yet._" })
  end,
  ["render: folds per section, separate limits, latest marked"] = function()
    local r = view.render(TURNS, { truncate = { chars = 100, prompt = 1000 } })
    h.eq(#r.folds, 2, "two long replies; the long prompt is under its own limit")
    h.eq(r.folds[1], { first = 10, last = 16, chars = 6 * 43 + 44 + 6 }) -- lines a4..a10
    h.eq(r.folds[2].latest, true)
  end,
  ["show: a read-only Markdown split with closed folds"] = function()
    reset()
    local prev = vim.api.nvim_get_current_win()
    local win, buf = show(TURNS)
    h.eq(#vim.api.nvim_tabpage_list_wins(0), 2)
    h.eq(vim.api.nvim_get_current_win(), win)
    h.eq(vim.bo[buf].filetype, "markdown")
    h.eq(vim.bo[buf].modifiable, false)
    h.eq(vim.api.nvim_win_get_width(win), 60)
    local st = view.state[buf]
    local folds = st.rendered.folds
    vim.api.nvim_win_call(win, function()
      h.eq(vim.fn.foldclosed(folds[1].first), folds[1].first, "older reply folded")
      h.eq(vim.fn.foldclosed(folds[#folds].first), -1, "newest reply open")
      h.eq(vim.fn.foldclosed(folds[2].first), folds[2].first, "long prompt folded")
    end)
    h.eq(vim.api.nvim_win_get_cursor(win)[1], st.rendered.headings[#st.rendered.headings].line)
    view.close()
    h.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
    h.eq(vim.api.nvim_get_current_win(), prev)
    h.eq(vim.api.nvim_buf_is_valid(buf), false, "buffer wiped")
  end,
  ["show: fold text says how much is hidden"] = function()
    reset()
    local win, buf = show({ { n = 1, prompt = "x", reply = table.concat(long(30), "\n") } }, {
      truncate = { chars = 100, open_latest = false },
    })
    local f = view.state[buf].rendered.folds[1]
    local text = vim.api.nvim_win_call(win, function()
      return vim.fn.foldtextresult(f.first)
    end)
    h.eq(text, "… 1,316 more characters (za to expand)")
    reset()
  end,
  ["show: a second call reuses the split"] = function()
    reset()
    local win1, buf1 = show(TURNS)
    local win2, buf2 = show({ { n = 1, prompt = "New", reply = "Text" } })
    h.eq(win2, win1)
    h.eq(buf2, buf1)
    h.eq(vim.api.nvim_buf_get_lines(buf2, 0, 1, false)[1], "# 1 · You")
    reset()
  end,
  ["keys: ]] and [[ jump between turns, q closes"] = function()
    reset()
    local win, buf = show(TURNS, { truncate = false })
    local hd = view.state[buf].rendered.headings
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.cmd("normal ]]")
    h.eq(vim.api.nvim_win_get_cursor(win)[1], hd[3].line, "next turn's prompt")
    vim.cmd("normal [[")
    h.eq(vim.api.nvim_win_get_cursor(win)[1], hd[1].line)
    vim.cmd("normal q")
    h.eq(#vim.api.nvim_tabpage_list_wins(0), 1)
  end,
  ["eunoe: :Eunoe end to end with a fake Claude Code parent"] = function()
    reset()
    local session = require("eunoe.session")
    local ctx
    session.context(function(c)
      ctx = c
    end)
    h.wait(function()
      return ctx ~= nil
    end)
    local ppid = ctx.chain[1]
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/sessions", "p")
    vim.fn.mkdir(root .. "/projects/p", "p")
    vim.fn.writefile({
      vim.json.encode({ pid = ppid, sessionId = "abc-123", cwd = ctx.cwd, procStart = ctx.procs[ppid].start }),
    }, ("%s/sessions/%d.json"):format(root, ppid))
    vim.fn.writefile(h.lines("claude/resumed.jsonl"), root .. "/projects/p/abc-123.jsonl")
    local old = vim.env.CLAUDE_CONFIG_DIR
    vim.env.CLAUDE_CONFIG_DIR = root
    local ok, err = pcall(function()
      vim.opt.rtp:prepend(h.root)
      vim.cmd("runtime plugin/eunoe.lua")
      vim.cmd("Eunoe")
      h.wait(function()
        return view.current() ~= nil
      end)
      local _, buf = view.current()
      h.eq(vim.api.nvim_buf_get_name(buf), "eunoe://claude/abc-123")
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      h.truthy(text:find("# 2 · You\n\nsay hi again", 1, true), text)
      vim.cmd("Eunoe")
      h.eq(view.current(), nil, "second :Eunoe closes")
      -- After a /clear: the sessions file points at an id without transcript.
      vim.fn.writefile({
        vim.json.encode({ pid = ppid, sessionId = "fresh", cwd = ctx.cwd, procStart = ctx.procs[ppid].start }),
      }, ("%s/sessions/%d.json"):format(root, ppid))
      vim.cmd("Eunoe")
      h.wait(function()
        return view.current() ~= nil
      end)
      local _, buf2 = view.current()
      h.eq(vim.api.nvim_buf_get_lines(buf2, 0, -1, false), { "_No conversation yet._" })
    end)
    vim.env.CLAUDE_CONFIG_DIR = old
    reset()
    if not ok then
      error(err, 0)
    end
  end,
  ["eunoe: no session found is a warning, not an error"] = function()
    reset()
    local old, notify = vim.env.CLAUDE_CONFIG_DIR, vim.notify
    local got
    vim.env.CLAUDE_CONFIG_DIR = vim.fn.tempname()
    vim.notify = function(msg, level)
      got = { msg = msg, level = level }
    end
    local ok, err = pcall(function()
      require("eunoe").open()
      h.wait(function()
        return got ~= nil
      end)
      h.eq(got.level, vim.log.levels.WARN)
      h.truthy(got.msg:find("no agent session found"), got.msg)
      h.eq(view.current(), nil)
    end)
    vim.env.CLAUDE_CONFIG_DIR, vim.notify = old, notify
    if not ok then
      error(err, 0)
    end
  end,
}
