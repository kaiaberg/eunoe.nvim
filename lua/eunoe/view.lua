--- The conversation buffer: rendering turns into Markdown with truncation
--- folds, and the split that shows it.
local M = {}

---@class eunoe.Fold
---@field first integer First folded line (1-based).
---@field last integer Last folded line.
---@field chars integer Characters hidden in the fold.
---@field latest boolean? Part of the newest reply.

---@class eunoe.Heading
---@field line integer 1-based line of the heading.
---@field turn integer Turn number.
---@field role "prompt"|"reply"

---@class eunoe.Rendered
---@field lines string[]
---@field folds eunoe.Fold[]
---@field headings eunoe.Heading[]
---@field sections { turn: integer, role: "prompt"|"reply", first: integer, last: integer, text: string }[]

local function is_fence(line)
  return line:match("^%s*```") or line:match("^%s*~~~")
end

--- Where to cut `lines` so that roughly `limit` characters stay visible:
--- the number of lines to keep, or nil when nothing should be folded. The
--- cut lands at a line end, never inside a fenced code block (it moves
--- before the fence, or after it when the fence starts the text).
---@param lines string[]
---@param limit integer
---@return integer?
function M.cut(lines, limit)
  local total, in_fence, fence_start = 0, false, nil
  for i, line in ipairs(lines) do
    if is_fence(line) then
      in_fence = not in_fence
      fence_start = in_fence and i or fence_start
    end
    total = total + #line + 1
    if total > limit then
      local keep = i
      if in_fence then
        if fence_start > 1 then
          keep = fence_start - 1
        else
          -- The text starts with the fence: keep it whole.
          keep = nil
          for j = i + 1, #lines do
            if is_fence(lines[j]) then
              keep = j
              break
            end
          end
          if not keep then
            return nil
          end
        end
      end
      -- Nothing (or only blank lines) left to fold.
      for j = keep + 1, #lines do
        if lines[j]:find("%S") then
          return keep
        end
      end
      return nil
    end
  end
  return nil
end

local width_of = vim.fn.strdisplaywidth

--- Break one line at spaces so no part is wider than `width`, keeping
--- Markdown structure: continuation lines of a list item are indented
--- under its text, quoted lines repeat their `>` prefix. A word wider than
--- `width` (a URL, say) stays whole.
---@param line string
---@param width integer
---@return string[]
local function wrap_line(line, width)
  if width_of(line) <= width then
    return { line }
  end
  local quote = line:match("^%s*>[>%s]*") or ""
  local rest = line:sub(#quote + 1)
  local indent = rest:match("^%s*")
  local marker = rest:match("^%s*[-*+]%s+") or rest:match("^%s*%d+[.)]%s+") or indent
  local first_prefix = quote .. marker
  local cont_prefix = quote .. string.rep(" ", width_of(marker))
  local words = vim.split(rest:sub(#marker + 1), "%s+", { trimempty = true })

  local out, cur, prefix = {}, nil, first_prefix
  for _, word in ipairs(words) do
    if cur and width_of(cur) + 1 + width_of(word) > width then
      out[#out + 1] = cur
      cur, prefix = nil, cont_prefix
    end
    cur = cur and (cur .. " " .. word) or (prefix .. word)
  end
  out[#out + 1] = cur or line
  return out
end

--- Break the lines of a section longer than `width` into several lines,
--- leaving fenced code blocks and table rows alone.
---@param lines string[]
---@param width integer
---@return string[]
function M.wrap(lines, width)
  local out, in_fence = {}, false
  for _, line in ipairs(lines) do
    if is_fence(line) then
      in_fence = not in_fence
      out[#out + 1] = line
    elseif in_fence or line:match("^%s*|") then
      out[#out + 1] = line
    else
      vim.list_extend(out, wrap_line(line, width))
    end
  end
  return out
end

--- Render turns into lines, with folds for long sections.
---@param turns eunoe.Turn[]
---@param opts { truncate: table|false, total: integer?, wrap: integer|false|nil }
---@return eunoe.Rendered
function M.render(turns, opts)
  local out = { lines = {}, folds = {}, headings = {}, sections = {} }
  local lines = out.lines
  local trunc = opts.truncate
  local function add(l)
    lines[#lines + 1] = l
  end
  local function section(turn, role, text, latest)
    add(("# %d · %s"):format(turn.n, role == "prompt" and "You" or "Agent"))
    out.headings[#out.headings + 1] = { line = #lines, turn = turn.n, role = role }
    add("")
    local body = vim.split(text, "\n", { plain = true })
    if opts.wrap then
      body = M.wrap(body, opts.wrap)
    end
    local first = #lines + 1
    for _, l in ipairs(body) do
      add(l)
    end
    out.sections[#out.sections + 1] = { turn = turn.n, role = role, first = first, last = #lines, text = text }
    if trunc then
      local limit = trunc[role] or trunc.chars
      local keep = limit and M.cut(body, limit)
      if keep then
        local hidden = table.concat(body, "\n", keep + 1)
        out.folds[#out.folds + 1] =
          { first = first + keep, last = first + #body - 1, chars = vim.fn.strchars(hidden), latest = latest or nil }
      end
    end
    add("")
  end

  if #turns == 0 then
    add("_No conversation yet._")
    return out
  end
  if opts.total and opts.total > #turns then
    add(("_The last %d of %d turns. `:Eunoe all` shows all of them._"):format(#turns, opts.total))
    add("")
  end
  for i, turn in ipairs(turns) do
    local latest = i == #turns
    if turn.prompt then
      section(turn, "prompt", turn.prompt)
    end
    local reply = turn.reply or "_(no reply)_"
    if turn.interrupted then
      reply = reply .. "\n\n_(interrupted)_"
    end
    section(turn, "reply", reply, latest)
  end
  -- Drop the trailing blank line.
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return out
end

-- Per-buffer state: rendered data, keyed by buffer number.
M.state = {}

local function group(n)
  local s = tostring(n)
  return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

--- Fold text: how much is hidden.
function M.foldtext()
  local st = M.state[vim.api.nvim_get_current_buf()]
  local fold = st and st.fold_at[vim.v.foldstart]
  if not fold then
    return vim.fn.foldtext()
  end
  return ("… %s more characters (za to expand)"):format(group(fold.chars))
end

local function find_win(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
end

--- The eunoe window in the current tab page, if any.
---@return integer? win, integer? buf
function M.current()
  for buf in pairs(M.state) do
    if vim.api.nvim_buf_is_valid(buf) then
      local win = find_win(buf)
      if win then
        return win, buf
      end
    else
      M.state[buf] = nil
    end
  end
end

local function width(spec)
  local cols = vim.o.columns
  local w = spec < 1 and math.floor(cols * spec) or spec
  return math.max(20, math.min(w, cols - 20))
end

local function apply_folds(win, st)
  vim.api.nvim_win_call(win, function()
    vim.cmd("silent! normal! zE")
    for _, f in ipairs(st.rendered.folds) do
      vim.cmd(("%d,%dfold"):format(f.first, f.last))
    end
    for _, f in ipairs(st.rendered.folds) do
      if f.latest and st.open_latest then
        vim.cmd(("silent! %dfoldopen"):format(f.first))
      end
    end
  end)
end

local function set_win_options(win)
  local wo = vim.wo[win]
  wo.foldmethod = "manual"
  wo.foldenable = true
  wo.foldtext = "v:lua.require'eunoe.view'.foldtext()"
  wo.foldcolumn = "0"
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.spell = false
  wo.wrap = true
  wo.linebreak = true
  wo.list = false
  wo.winfixwidth = true
  wo.fillchars = "fold: ,eob: "
end

--- Jump to the next (`dir` = 1) or previous (-1) turn.
---@param buf integer
---@param dir 1|-1
function M.jump(buf, dir)
  local st = M.state[buf]
  if not st then
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local targets, last_turn = {}, nil
  for _, h in ipairs(st.rendered.headings) do
    if h.turn ~= last_turn then
      targets[#targets + 1] = h.line
      last_turn = h.turn
    end
  end
  local count = vim.v.count1
  local pick = row
  for _ = 1, count do
    local nxt
    if dir > 0 then
      for _, l in ipairs(targets) do
        if l > pick then
          nxt = l
          break
        end
      end
    else
      for i = #targets, 1, -1 do
        if targets[i] < pick then
          nxt = targets[i]
          break
        end
      end
    end
    if not nxt then
      break
    end
    pick = nxt
  end
  if pick ~= row then
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(0, { pick, 0 })
  end
end

local function set_keymaps(buf, handlers)
  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map("q", handlers.close, "eunoe: close")
  map("]]", function()
    M.jump(buf, 1)
  end, "eunoe: next turn")
  map("[[", function()
    M.jump(buf, -1)
  end, "eunoe: previous turn")
  map("R", handlers.reload, "eunoe: reload")
end

--- Put the cursor on the newest reply's heading, at the top of the window.
local function place_cursor(win, st)
  local headings = st.rendered.headings
  local h = headings[#headings]
  if not h then
    return
  end
  vim.api.nvim_win_call(win, function()
    vim.api.nvim_win_set_cursor(win, { h.line, 0 })
    vim.cmd("normal! zt")
  end)
end

--- Show rendered turns in the eunoe split, creating it if needed.
---@param turns eunoe.Turn[]
---@param opts { name: string, total: integer?, truncate: table|false, wrap: integer|false|nil, width: number, focus: boolean, handlers: table }
---@return integer win, integer buf
function M.show(turns, opts)
  local rendered = M.render(turns, { truncate = opts.truncate, total = opts.total, wrap = opts.wrap })
  local win, buf = M.current()
  if not buf then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      callback = function()
        M.state[buf] = nil
      end,
    })
  end
  pcall(vim.api.nvim_buf_set_name, buf, opts.name)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rendered.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  local fold_at = {}
  for _, f in ipairs(rendered.folds) do
    fold_at[f.first] = f
  end
  local st = {
    rendered = rendered,
    fold_at = fold_at,
    open_latest = opts.truncate and opts.truncate.open_latest,
  }
  M.state[buf] = st
  set_keymaps(buf, opts.handlers)

  local prev = vim.api.nvim_get_current_win()
  if not win then
    win = vim.api.nvim_open_win(buf, false, { split = "right", win = -1, width = width(opts.width) })
    st.prev_win = prev
  end
  set_win_options(win)
  apply_folds(win, st)
  place_cursor(win, st)
  if opts.focus then
    vim.api.nvim_set_current_win(win)
  end
  return win, buf
end

--- Close the eunoe split in the current tab page and return to the window
--- it was opened from.
function M.close()
  local win, buf = M.current()
  if not win then
    return
  end
  local prev = M.state[buf] and M.state[buf].prev_win
  if #vim.api.nvim_tabpage_list_wins(0) == 1 then
    vim.cmd("enew")
  else
    vim.api.nvim_win_close(win, true)
  end
  if prev and vim.api.nvim_win_is_valid(prev) then
    vim.api.nvim_set_current_win(prev)
  end
end

return M
