local h = require("helpers")
local view = require("eunoe.view")

local function reset()
  vim.cmd("silent! only")
  vim.cmd("enew!")
  for buf in pairs(view.state) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  view.state = {}
end

--- Render and return a selection helper over the rendered lines.
local function rendered(turns, wrap)
  local r = view.render(turns, { truncate = false, wrap = wrap })
  local function get(l)
    return r.lines[l]
  end
  return r, function(l1, c1, l2, c2)
    return view.selected_text(r, get, l1, c1, l2, c2)
  end
end

--- Line number of the first rendered line equal to `text`.
local function find(r, text)
  for i, l in ipairs(r.lines) do
    if l == text then
      return i
    end
  end
  error("no line " .. text)
end

--- A prompt buffer with `lines` and the cursor on `row`, then the eunoe
--- split opened from it.
local function setup(lines, row, turns, wrap)
  reset()
  local prompt_win = vim.api.nvim_get_current_win()
  local prompt_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(prompt_win, { row, 0 })
  local win, buf = view.show(turns, {
    name = "eunoe://test/quote" .. math.random(1e9),
    truncate = false,
    wrap = wrap,
    width = 60,
    focus = true,
    handlers = { close = view.close, reload = function() end },
  })
  return prompt_win, prompt_buf, win, buf
end

local TURNS = {
  { n = 1, prompt = "What now?", reply = "Three things:\n\n1. Parse.\n2. Render.\n3. Quote the  spaced  text." },
}

return {
  ["selected_text: lines of a message, headings and separators skipped"] = function()
    local r, sel = rendered(TURNS)
    h.eq(
      sel(1, 1, #r.lines, math.huge),
      "What now?\n\nThree things:\n\n1. Parse.\n2. Render.\n3. Quote the  spaced  text."
    )
    local l = find(r, "2. Render.")
    h.eq(sel(l, 1, l + 1, math.huge), "2. Render.\n3. Quote the  spaced  text.")
  end,
  ["selected_text: messages become separate paragraphs"] = function()
    local r, sel = rendered(TURNS)
    h.eq(sel(1, 1, find(r, "Three things:"), math.huge), "What now?\n\nThree things:")
  end,
  ["selected_text: charwise picks the exact part"] = function()
    local r, sel = rendered(TURNS)
    local l = find(r, "3. Quote the  spaced  text.")
    h.eq(sel(l, 4, l, 8), "Quote")
  end,
  ["selected_text: wrapped lines join back with the original spacing"] = function()
    local reply = "- alpha beta  gamma delta epsilon zeta"
    local r, sel = rendered({ { n = 1, reply = reply } }, 14)
    local first = find(r, "- alpha beta")
    h.eq(r.lines[first + 1], "  gamma delta")
    h.eq(sel(first, 1, first + 2, math.huge), reply, "linewise over all pieces")
    -- From "beta" (cols 9-12 of the first piece) to "delta" in the second.
    h.eq(sel(first, 9, first + 1, 13), "beta  gamma delta")
    -- Starting inside a continuation's indent skips the indent.
    h.eq(sel(first + 1, 1, first + 1, 7), "gamma")
  end,
  ["insert_quote: below a line with text, cursor after the quote"] = function()
    local prompt_win, prompt_buf = setup({ "About this:", "more text" }, 1, TURNS)
    view.insert_quote(prompt_win, "1. Parse.\n\n2. Render.")
    h.eq(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false), {
      "About this:",
      "",
      "> 1. Parse.",
      ">",
      "> 2. Render.",
      "",
      "",
      "more text",
    })
    h.eq(vim.api.nvim_get_current_win(), prompt_win)
    h.eq(vim.api.nvim_win_get_cursor(prompt_win)[1], 6)
    reset()
  end,
  ["insert_quote: an empty prompt gets the quote and a line to type on"] = function()
    local prompt_win, prompt_buf = setup({ "" }, 1, TURNS)
    view.insert_quote(prompt_win, "Parse.")
    h.eq(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false), { "> Parse.", "" })
    h.eq(vim.api.nvim_win_get_cursor(prompt_win)[1], 2)
    reset()
  end,
  ["insert_quote: a blank first line above text"] = function()
    local prompt_win, prompt_buf = setup({ "", "below" }, 1, TURNS)
    view.insert_quote(prompt_win, "Q")
    h.eq(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false), { "> Q", "", "", "below" })
    h.eq(vim.api.nvim_win_get_cursor(prompt_win)[1], 2)
    reset()
  end,
  ["insert_quote: a blank line between text is replaced"] = function()
    local prompt_win, prompt_buf = setup({ "above", "", "below" }, 2, TURNS)
    view.insert_quote(prompt_win, "Q")
    h.eq(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false), { "above", "", "> Q", "", "", "below" })
    h.eq(vim.api.nvim_win_get_cursor(prompt_win)[1], 4)
    reset()
  end,
  ["> in Visual mode quotes into the window eunoe was opened from"] = function()
    local prompt_win, prompt_buf, win, buf = setup({ "My prompt" }, 1, TURNS)
    local r = view.state[buf].rendered
    local l = find(r, "2. Render.")
    vim.api.nvim_win_set_cursor(win, { l, 0 })
    vim.cmd("normal Vj>")
    h.eq(vim.api.nvim_get_current_win(), prompt_win)
    h.eq(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false), {
      "My prompt",
      "",
      "> 2. Render.",
      "> 3. Quote the  spaced  text.",
      "",
    })
    h.eq(vim.fn.mode(), "n")
    reset()
  end,
  ["> charwise, across a wrapped line"] = function()
    local reply = "one two three four five six seven eight nine ten"
    local prompt_win, prompt_buf, win = setup({ "" }, 1, { { n = 1, reply = reply } }, 20)
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    local first
    for i, l in ipairs(lines) do
      if l:find("^one two") then
        first = i
      end
    end
    -- "three" starts at col 9 on the first piece; select to the end of "six".
    vim.api.nvim_win_set_cursor(win, { first, 8 })
    local second = lines[first + 1]
    local six_end = second:find("six", 1, true) + 2
    vim.cmd(("normal v%dj0%dl>"):format(1, six_end - 1))
    h.eq(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false), { "> three four five six", "" })
    h.eq(vim.api.nvim_get_current_win(), prompt_win)
    reset()
  end,
  ["keys: false leaves a key unmapped, other keys can be changed"] = function()
    reset()
    local _, buf = view.show(TURNS, {
      name = "eunoe://test/keys",
      truncate = false,
      width = 60,
      focus = true,
      handlers = { close = view.close, reload = function() end },
      keys = { close = "Q", quote = false },
    })
    local function mapped(mode, lhs)
      return vim.fn.maparg(lhs, mode, false, true).buffer == 1
    end
    h.eq(mapped("n", "Q"), true)
    h.eq(mapped("n", "q"), false)
    h.eq(mapped("x", ">"), false)
    h.truthy(vim.api.nvim_buf_is_valid(buf))
    reset()
  end,
}
