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
  view.level = nil
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
    h.eq(r.lines, { "1 · You", "Hi", "", "1 · Agent", "Hello", "there" })
    h.eq(r.headings, {
      { line = 1, turn = 1, role = "prompt", last = 3, section = 1 },
      { line = 4, turn = 1, role = "reply", last = 6, section = 2 },
    })
    h.eq(r.folds, {})
    h.eq(
      r.sections[2],
      { turn = 1, role = "reply", first = 5, last = 6, text = "Hello\nthere", lines = { "Hello", "there" } }
    )
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
      "1 · Agent",
      "Orphan",
      "",
      "2 · You",
      "Go",
      "",
      "2 · Agent",
      "_(no reply)_",
      "",
      "_(interrupted)_",
    })
    h.eq(view.render({}, { truncate = false }).lines, { "_No conversation yet._" })
  end,
  ["render: folds per section, separate limits, latest marked"] = function()
    local r = view.render(TURNS, { truncate = { chars = 100, prompt = 1000 } })
    h.eq(#r.folds, 2, "two long replies; the long prompt is under its own limit")
    h.eq(r.folds[1], { first = 8, last = 14, chars = 6 * 43 + 44 + 6 }) -- lines a4..a10
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
    h.eq(vim.api.nvim_buf_get_lines(buf2, 0, 1, false)[1], "1 · You")
    reset()
  end,
  ["render: the agent's heading name, Agent by default"] = function()
    local r = view.render({ { n = 3, prompt = "Hi", reply = "Hello" } }, { truncate = false, agent = "Claude" })
    h.eq(r.lines[1], "3 · You")
    h.eq(r.lines[4], "3 · Claude")
  end,
  ["show: headings get colors and icons as extmarks, the text stays plain"] = function()
    reset()
    local _, buf = show({ { n = 1, prompt = "Hi", reply = "Hello" } }, {
      style = "bar",
      agent = "Bot",
      speakers = { prompt = { hl = "EunoeUser", icon = "U" }, reply = { hl = "EunoeAgent", icon = false } },
    })
    h.eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "1 · You", "Hi", "", "1 · Bot", "Hello" })
    local marks = vim.api.nvim_buf_get_extmarks(buf, require("eunoe.highlight").ns, 0, -1, { details = true })
    local got = vim.tbl_map(function(m)
      local d = m[4]
      return { m[2], m[3], d.hl_group or false, d.virt_text and d.virt_text[1][1] or false, d.end_col or false }
    end, marks)
    table.sort(got, function(a, b)
      return a[1] * 100 + a[2] < b[1] * 100 + b[2] or (a[1] == b[1] and a[2] == b[2] and a[3] ~= false)
    end)
    h.eq(got, {
      { 0, 0, "EunoeUser", false, 8 },
      { 0, 5, false, "U ", false },
      { 3, 0, "EunoeAgent", false, 8 },
    })
    reset()
  end,
  ["heading_line: every combination of number, separator, icon and name"] = function()
    local function line(icon, h)
      return { view.heading_line(7, "You", icon, h) }
    end
    h.eq(line("I", {}), { "7 · You", 5, "I " })
    h.eq(line(nil, {}), { "7 · You" })
    h.eq(line("I", { separator = false }), { "7 You", 2, "I " })
    h.eq(line("I", { number = false }), { "You", 0, "I " })
    h.eq(line("I", { names = false }), { "7 ·", 4, " I" })
    h.eq(line(nil, { names = false }), { "7" }, "no separator without anything after it")
    h.eq(line("I", { number = false, names = false }), { "", 0, "I" })
    h.eq(line(false, { number = false, names = false }), { "" })
  end,
  ["render: a blank line after the heading where the message would merge with it"] = function()
    local function second(reply)
      return view.render({ { n = 1, reply = reply } }, { truncate = false }).lines[2]
    end
    h.eq(second("Text"), "Text")
    h.eq(second("- item"), "- item")
    h.eq(second("1. first"), "1. first")
    h.eq(second("```lua\nx\n```"), "```lua")
    h.eq(second("| a | b |\n|---|---|"), "| a | b |")
    for _, merging in ipairs({ "---", "===", "    code()", "\tcode()", "3. third" }) do
      h.eq(second(merging), "", merging)
    end
    local r = view.render({ { n = 1, reply = "---\nmore" } }, { truncate = false })
    h.eq(r.sections[1].first, 3, "the message starts after the blank line")
  end,
  ["oneline: pad lines up numbers and names, pad = false doesn't"] = function()
    local r = view.render({ { n = 9, prompt = "a", reply = "b" }, { n = 10, prompt = "c", reply = "d" } }, {
      truncate = false,
      agent = "Claude",
    })
    local st = { rendered = r, speakers = { prompt = { hl = "U" }, reply = { hl = "A" } }, heading = {} }
    local function row(i)
      return vim.fn.join(
        vim.tbl_map(function(c)
          return c[1]
        end, view.message_line(st, st.rendered.headings[i], 60)),
        ""
      )
    end
    h.eq({ row(1), row(2), row(3) }, { " 9 · You     a", " 9 · Claude  b", "10 · You     c" })
    st.heading = { pad = false }
    h.eq({ row(1), row(2) }, { "9 · You  a", "9 · Claude  b" })
    -- Bar style draws the time right-aligned over the row: the text leaves
    -- room. Box style puts the time at the row's end.
    local long = view.render({ { n = 1, prompt = string.rep("word ", 30), reply = "b" } }, { truncate = false })
    long.headings[1].time = "2026-11-11T09:30:00Z"
    st.rendered = long
    local clock = view.clock("2026-11-11T09:30:00Z")
    st.style = "bar"
    h.eq(vim.fn.strdisplaywidth(row(1)), 60 - #clock - 1)
    st.style = "box"
    h.eq(vim.fn.strdisplaywidth(row(1)), 60)
    h.truthy(row(1):find("… " .. clock .. "$"), row(1))
    st.heading = { time = false }
    h.eq(vim.fn.strdisplaywidth(row(1)), 60)
  end,
  ["show: heading.time = false leaves out the time"] = function()
    reset()
    local turns = { { n = 1, prompt = "Hi", reply = "Yo", time = "2026-11-11T09:30:00Z" } }
    local _, buf = show(turns, { heading = { time = false } })
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
      h.truthy(m[4].virt_text_pos ~= "right_align", "a time was shown")
    end
    reset()
  end,
  ["clock: local time today, with the date before"] = function()
    local t = view.epoch("2026-11-11T09:30:00.123Z")
    h.eq(t, 1794389400)
    h.eq(view.clock("2026-11-11T09:30:00Z", t + 60), os.date("%H:%M", t))
    h.eq(view.clock("2026-11-11T09:30:00Z", t + 3 * 86400), os.date("%b %d %H:%M", t))
    h.eq(view.clock("yesterday"), nil)
    h.eq(view.clock(nil), nil)
  end,
  ["show: the left column, box style and bar style"] = function()
    reset()
    local turns = {
      { n = 1, prompt = "Hi", reply = "Hello\nthere", time = "2026-11-11T09:30:00Z" },
      { n = 2, prompt = "More", reply = "Yes" },
    }
    local win, buf = show(turns, { bar = "▎" })
    h.eq(vim.wo[win].signcolumn, "no")
    h.truthy(vim.wo[win].statuscolumn:find("statuscolumn", 1, true), "eunoe's statuscolumn")
    local function column()
      local out = {}
      for l = 1, vim.api.nvim_buf_line_count(buf) do
        out[#out + 1] = (view.left_column(win, l, 0))
      end
      return out
    end
    -- 1 · You / Hi / (sep) / 1 · Agent / Hello / there / (sep) / 2 · You / More / (sep) / 2 · Agent / Yes
    h.eq(
      column(),
      { "╭─", "│ ", "╰─", "╭─", "│ ", "│ ", "╰─", "╭─", "│ ", "╰─", "╭─", "│ " }
    )
    h.eq({ view.left_column(win, 5, 1) }, { "│ ", "EunoeAgent" }, "wrapped rows too")
    h.eq((view.left_column(win, 12, -1)), "  ", "virtual lines")
    vim.cmd("normal o")
    h.eq((view.left_column(win, 1, 0)), "▎ ", "one-line rows get the bar")
    vim.cmd("normal o")
    show(turns, { style = "bar", bar = "▎" })
    h.eq(column(), { "▎ ", "▎ ", "  ", "▎ ", "▎ ", "▎ ", "  ", "▎ ", "▎ ", "  ", "▎ ", "▎ " })
    show(turns, { style = "bar", bar = false })
    h.eq((view.left_column(win, 1, 0)), "", "no bar, no column")
    reset()
  end,
  ["show: the box's borders and the time"] = function()
    reset()
    local turns = {
      { n = 1, prompt = "Hi", reply = "Hello", time = "2026-11-11T09:30:00Z" },
      { n = 2, prompt = "More", reply = "Yes" },
    }
    local _, buf = show(turns, { wrap = 40 })
    local ns = require("eunoe.highlight").ns
    local by_row = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      local d = m[4]
      local text = d.virt_text and table.concat(vim.tbl_map(function(c)
        return c[1]
      end, d.virt_text)) or d.virt_lines and d.virt_lines[1][1][1]
      if text and text ~= " " then
        by_row[m[2]] = by_row[m[2]] or {}
        table.insert(by_row[m[2]], { d.virt_text_pos or "virt_lines", text })
      end
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    -- The heading row adds up to the box width: " " + heading + eol gap + fill + time.
    local top = by_row[0][1]
    h.eq(top[1], "eol")
    local clock = view.clock("2026-11-11T09:30:00Z")
    h.truthy(top[2]:find(clock .. "$"), top[2])
    h.eq(1 + vim.fn.strdisplaywidth(lines[1]) + 1 + vim.fn.strdisplaywidth(top[2]), 41)
    h.eq(by_row[2][1], { "overlay", string.rep("─", 41) }, "bottom border over the separator")
    local last = by_row[#lines - 1]
    h.eq(last[#last], { "virt_lines", "╰─" .. string.rep("─", 41) }, "below the last message")
    -- In one-line mode the time moves into the row.
    local st = view.state[buf]
    local row = table.concat(vim.tbl_map(function(c)
      return c[1]
    end, view.message_line(st, st.rendered.headings[1], 40)))
    h.truthy(row:find(clock .. "$"), row)
    h.eq(vim.fn.strdisplaywidth(row), 40)
    reset()
  end,
  ["show: lines wrap at the window's width when it is narrower than view.wrap"] = function()
    reset()
    local words = string.rep("word ", 40)
    local _, buf = show({ { n = 1, prompt = words, reply = "ok" } }, { wrap = 80, width = 40, bar = "▎" })
    for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      h.truthy(vim.fn.strdisplaywidth(l) <= 40 - 3, "too wide: " .. l)
    end
    reset()
  end,
  ["flatten: one line, without fences and Markdown markers"] = function()
    h.eq(
      view.flatten({ "## Plan", "", "> quoted  text", "```lua", "x = 1", "```", "- item" }),
      "Plan quoted text x = 1 - item"
    )
  end,
  ["oneline: o folds every message to one line and back, the cursor stays"] = function()
    reset()
    view.level = view.DEFAULT
    local win, buf =
      show(TURNS, { speakers = { prompt = { hl = "EunoeUser", icon = "U" }, reply = { hl = "EunoeAgent" } } })
    local st = view.state[buf]
    local hd = st.rendered.headings
    -- The first reply, inside its text.
    vim.api.nvim_win_set_cursor(win, { hd[2].line + 3, 0 })
    vim.cmd("normal o")
    h.eq(vim.wo[win].foldlevel, view.ONELINE)
    for _, x in ipairs(hd) do
      h.eq(vim.fn.foldclosed(x.line), x.line, "message folded")
      h.eq(vim.fn.foldclosedend(x.line), x.last)
    end
    h.eq(vim.fn.foldclosed(vim.fn.line(".")), hd[2].line, "cursor on the same message")
    local text = vim.fn.foldtextresult(hd[1].line)
    h.eq(text, "1 · U You    First?", "You padded to the width of Agent")
    local reply = vim.fn.foldtextresult(hd[2].line)
    h.truthy(reply:find("^1 · Agent  a1 x+ a2"), reply)
    h.truthy(vim.fn.strdisplaywidth(reply) <= 60, "fits the window: " .. reply)
    h.truthy(reply:find("…$"), reply)
    st.wrap = 40
    h.eq(vim.fn.strdisplaywidth(vim.fn.foldtextresult(hd[2].line)), 40, "capped at view.wrap")
    st.wrap = nil
    vim.cmd("normal j")
    h.eq(vim.fn.foldclosed(vim.fn.line(".")), hd[3].line, "j goes to the next message")
    vim.cmd("normal o")
    h.eq(vim.wo[win].foldlevel, view.DEFAULT)
    h.eq(vim.fn.line("."), hd[3].line, "back on the same message")
    local folds = st.rendered.folds
    h.eq(vim.fn.foldclosed(folds[1].first), folds[1].first, "truncation folds closed again")
    h.eq(vim.fn.foldclosed(folds[#folds].first), -1, "newest reply open again")
    reset()
  end,
  ["oneline: the mode survives a reload, zR and zM included"] = function()
    reset()
    view.level = view.DEFAULT
    local win = show(TURNS)
    vim.cmd("normal o")
    show(TURNS)
    h.eq(vim.wo[win].foldlevel, view.ONELINE, "after R")
    vim.cmd("normal zR")
    show(TURNS)
    h.eq(vim.wo[win].foldlevel >= view.EXPANDED, true, "zR kept")
    vim.cmd("normal o")
    h.eq(vim.wo[win].foldlevel, view.ONELINE)
    vim.cmd("normal o")
    h.eq(vim.wo[win].foldlevel >= view.EXPANDED, true, "o goes back to the mode before")
    view.close()
    local win2 = show(TURNS)
    h.eq(vim.wo[win2].foldlevel >= view.EXPANDED, true, "kept across closing")
    view.level = view.DEFAULT
    reset()
  end,
  ["modes: O toggles expanded and back, o and O go back to where they came from"] = function()
    reset()
    local win = show(TURNS)
    h.eq(view.mode(win), "default")
    vim.cmd("normal O")
    h.eq(view.mode(win), "expanded")
    for _, f in ipairs(view.state[vim.api.nvim_win_get_buf(win)].rendered.folds) do
      h.eq(vim.fn.foldclosed(f.first), -1, "everything open")
    end
    vim.cmd("normal o")
    h.eq(view.mode(win), "oneline")
    vim.cmd("normal o")
    h.eq(view.mode(win), "expanded", "o goes back to expanded")
    vim.cmd("normal O")
    h.eq(view.mode(win), "oneline", "O goes back to one-line")
    vim.cmd("normal O")
    h.eq(view.mode(win), "expanded")
    reset()
  end,
  ["modes: the cycle key, and view.mode for the first open"] = function()
    reset()
    local keys = vim.tbl_extend("force", require("eunoe.config").defaults.keys, { cycle = "<Tab>" })
    local win = show(TURNS, { keys = keys, mode = "oneline" })
    h.eq(view.mode(win), "oneline", "opens in view.mode")
    local seen = {}
    for _ = 1, 3 do
      vim.api.nvim_feedkeys(vim.keycode("<Tab>"), "x", false)
      seen[#seen + 1] = view.mode(win)
    end
    h.eq(seen, { "default", "expanded", "oneline" })
    vim.cmd("normal zR")
    show(TURNS, { keys = keys, mode = "oneline" })
    h.eq(view.mode(win), "expanded", "a reload keeps the mode, not view.mode")
    reset()
  end,
  ["modes: eunoe.mode() and :Eunoe mode"] = function()
    reset()
    local eunoe = require("eunoe")
    h.eq(eunoe.mode(), "default", "closed: the mode it will open in")
    local win = show(TURNS)
    h.eq(eunoe.mode("expanded"), "expanded")
    h.eq(view.mode(win), "expanded")
    vim.opt.rtp:prepend(h.root)
    vim.cmd("runtime plugin/eunoe.lua")
    vim.cmd("Eunoe mode oneline")
    h.eq(eunoe.mode(), "oneline")
    h.eq(vim.fn.getcompletion("Eunoe mode ", "cmdline"), { "default", "expanded", "oneline" })
    h.eq(vim.fn.getcompletion("Eunoe m", "cmdline"), { "mode" })
    h.truthy(not pcall(eunoe.mode, "folded"), "unknown mode")
    reset()
  end,
  ["heading_at: the message at a line"] = function()
    local r = view.render(TURNS, { truncate = false, total = 3 })
    h.eq(view.heading_at(r, 1), nil, "the note above the first heading")
    local hd = r.headings
    h.eq(view.heading_at(r, hd[1].line), hd[1])
    h.eq(view.heading_at(r, hd[2].line - 1), hd[1], "the gap belongs to the message above")
    h.eq(view.heading_at(r, hd[4].line + 3), hd[4])
  end,
  ["status: b:eunoe_status and User EunoeStatus follow the cursor and the mode"] = function()
    reset()
    local events = {}
    local id = vim.api.nvim_create_autocmd("User", {
      pattern = "EunoeStatus",
      callback = function(ev)
        events[#events + 1] = ev.data
      end,
    })
    local win, buf = show(TURNS, { session = { reader = "claude", id = "abc", label = "Claude Code" }, total = 5 })
    local st = vim.b[buf].eunoe_status
    h.eq(st.agent, "Claude Code")
    h.eq({ st.reader, st.session, st.turns, st.total, st.mode }, { "claude", "abc", 2, 5, "default" })
    h.eq({ st.turn, st.role, st.speaker }, { 2, "reply", "Agent" }, "the cursor starts on the newest reply")
    h.eq(events[#events], st)
    local n = #events
    local hd = view.state[buf].rendered.headings
    vim.api.nvim_win_set_cursor(win, { hd[1].line, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    h.eq({ vim.b[buf].eunoe_status.turn, vim.b[buf].eunoe_status.role }, { 1, "prompt" })
    h.eq(#events, n + 1)
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    h.eq(#events, n + 1, "no event when nothing changed")
    vim.cmd("normal zR")
    h.eq(vim.b[buf].eunoe_status.mode, "expanded", "zR refreshes the status")
    vim.cmd("normal o")
    h.eq(vim.b[buf].eunoe_status.mode, "oneline")
    h.eq(require("eunoe").status(), view.status(buf))
    vim.api.nvim_del_autocmd(id)
    reset()
    h.eq(require("eunoe").status(), nil, "no split")
  end,
  ["show: a reload keeps the window eunoe was opened from"] = function()
    reset()
    local prev = vim.api.nvim_get_current_win()
    local _, buf = show(TURNS)
    show(TURNS)
    h.eq(view.state[buf].prev_win, prev)
    reset()
  end,
  ["show: focus = false leaves the cursor in the window it came from"] = function()
    reset()
    local prev = vim.api.nvim_get_current_win()
    local win, buf = show(TURNS, { focus = false })
    h.eq(vim.api.nvim_get_current_win(), prev)
    local hd = view.state[buf].rendered.headings
    h.eq(vim.api.nvim_win_get_cursor(win)[1], hd[#hd].line, "the split's cursor is on the newest reply")
    reset()
  end,
  ["auto_close: quitting the last other window quits, the rest doesn't"] = function()
    reset()
    local quits = 0
    local real = view._quit
    view._quit = function()
      quits = quits + 1
    end
    local ok, err = pcall(function()
      local function settle()
        vim.wait(50, function()
          return false
        end)
      end
      -- :q in the window eunoe was opened from: eunoe quits too.
      local main = vim.api.nvim_get_current_win()
      vim.cmd("vsplit")
      local other = vim.api.nvim_get_current_win()
      show(TURNS, { focus = false })
      vim.api.nvim_set_current_win(main)
      vim.cmd("quit")
      settle()
      h.eq(quits, 0, "another window is still open")
      vim.api.nvim_set_current_win(other)
      vim.cmd("quit")
      settle()
      h.eq(quits, 1, "only eunoe was left")
      -- :close and :only don't count, nor quitting eunoe itself.
      reset()
      vim.cmd("vsplit")
      show(TURNS, { focus = false })
      vim.cmd("close")
      settle()
      h.eq(quits, 1, ":close")
      local win = view.current()
      vim.api.nvim_set_current_win(win)
      vim.cmd("only")
      settle()
      h.eq(quits, 1, ":only")
      -- view.auto_close = false
      reset()
      show(TURNS, { focus = false, auto_close = false })
      vim.cmd("quit")
      settle()
      h.eq(quits, 1, "auto_close = false")
      -- With another tab page, only this tab page closes.
      reset()
      vim.cmd("tabnew")
      local tabs = #vim.api.nvim_list_tabpages()
      show(TURNS, { focus = false })
      vim.cmd("quit")
      settle()
      h.eq(#vim.api.nvim_list_tabpages(), tabs - 1, "the tab page closed")
      h.eq(quits, 1, "Neovim keeps running")
    end)
    view._quit = real
    vim.cmd("silent! tabonly")
    reset()
    if not ok then
      error(err, 0)
    end
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
      h.truthy(text:find("2 · You\nsay hi again", 1, true), text)
      h.truthy(text:find("2 · Claude\n", 1, true), text)
      local icons = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        if m[4].virt_text and m[4].virt_text_pos == "inline" and m[4].virt_text[1][1] ~= " " then
          icons[m[4].virt_text[1][1]] = m[4].virt_text[1][2]
        end
      end
      h.eq(icons, { ["\u{f007} "] = "EunoeUser", ["\u{ec82} "] = "EunoeAgentClaude" })
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
