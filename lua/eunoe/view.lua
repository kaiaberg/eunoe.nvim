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
---@field sections { turn: integer, role: "prompt"|"reply", first: integer, last: integer, text: string, lines: string[] }[]
---@field line_info table<integer, { section: integer, src: integer, skip: integer, delta: integer }> Rendered line → where its text comes from.

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

---@class eunoe.Piece
---@field text string The rendered line.
---@field skip integer Leading bytes that aren't source text (a continuation's indent).
---@field delta integer Source byte = rendered byte + delta, for bytes after `skip`.

--- Break one line at spaces so no part is wider than `width`, keeping
--- Markdown structure: continuation lines of a list item are indented
--- under its text, quoted lines repeat their `>` prefix. A word wider than
--- `width` (a URL, say) stays whole. The spacing between words is kept, so
--- every piece maps back to a byte range of the original line.
---@param line string
---@param width integer
---@return eunoe.Piece[]
local function wrap_line(line, width)
  if width_of(line) <= width then
    return { { text = line, skip = 0, delta = 0 } }
  end
  local quote = line:match("^%s*>[>%s]*") or ""
  local rest = line:sub(#quote + 1)
  local marker = rest:match("^%s*[-*+]%s+") or rest:match("^%s*%d+[.)]%s+") or rest:match("^%s*")
  local head = #quote + #marker -- bytes of the first piece's prefix
  local cont = quote .. string.rep(" ", width_of(marker))

  local words = {}
  for ws, we in line:sub(head + 1):gmatch("()%S+()") do
    words[#words + 1] = { head + ws, head + we - 1 }
  end
  if #words == 0 then
    return { { text = line, skip = 0, delta = 0 } }
  end

  local pieces = {}
  local first_word = 1
  local function piece_width(from, to)
    local prefix_width = #pieces == 0 and width_of(line:sub(1, head)) or width_of(cont)
    return prefix_width + width_of(line:sub(words[from][1], words[to][2]))
  end
  local function emit(from, to)
    local ws, we = words[from][1], words[to][2]
    if #pieces == 0 then
      pieces[1] = { text = line:sub(1, we), skip = 0, delta = 0 }
    else
      pieces[#pieces + 1] = { text = cont .. line:sub(ws, we), skip = #cont, delta = ws - #cont - 1 }
    end
  end
  for i = 2, #words do
    if piece_width(first_word, i) > width then
      emit(first_word, i - 1)
      first_word = i
    end
  end
  emit(first_word, #words)
  return pieces
end

--- Break the lines of a section longer than `width` into several lines,
--- leaving fenced code blocks and table rows alone.
---@param lines string[]
---@param width integer|false|nil No wrapping when false or nil.
---@return string[] lines
---@return { src: integer, skip: integer, delta: integer }[] info Per output line: its source line and offsets.
function M.wrap(lines, width)
  local out, info, in_fence = {}, {}, false
  local function keep(i, line)
    out[#out + 1] = line
    info[#info + 1] = { src = i, skip = 0, delta = 0 }
  end
  for i, line in ipairs(lines) do
    if is_fence(line) then
      in_fence = not in_fence
      keep(i, line)
    elseif not width or in_fence or line:match("^%s*|") then
      keep(i, line)
    else
      for _, p in ipairs(wrap_line(line, width)) do
        out[#out + 1] = p.text
        info[#info + 1] = { src = i, skip = p.skip, delta = p.delta }
      end
    end
  end
  return out, info
end

--- Render turns into lines, with folds for long sections.
---@param turns eunoe.Turn[]
---@param opts { truncate: table|false, total: integer?, wrap: integer|false|nil }
---@return eunoe.Rendered
function M.render(turns, opts)
  local out = { lines = {}, folds = {}, headings = {}, sections = {}, line_info = {} }
  local lines = out.lines
  local trunc = opts.truncate
  local function add(l)
    lines[#lines + 1] = l
  end
  local function section(turn, role, text, latest)
    add(("# %d · %s"):format(turn.n, role == "prompt" and "You" or "Agent"))
    out.headings[#out.headings + 1] = { line = #lines, turn = turn.n, role = role }
    add("")
    local source = vim.split(text, "\n", { plain = true })
    local body, info = M.wrap(source, opts.wrap)
    local first = #lines + 1
    out.sections[#out.sections + 1] =
      { turn = turn.n, role = role, first = first, last = first + #body - 1, text = text, lines = source }
    for i, l in ipairs(body) do
      add(l)
      out.line_info[#lines] = vim.tbl_extend("force", info[i], { section = #out.sections })
    end
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

--- The text of a selection, from the original turn text: lines split by
--- `view.wrap` are joined back, continuation indents left out. Lines outside
--- messages (headings, blank separators) are skipped; selected parts of
--- different messages become separate paragraphs.
---@param rendered eunoe.Rendered
---@param get_line fun(lnum: integer): string
---@param l1 integer First line (1-based).
---@param c1 integer First byte column (1-based); 1 for a linewise selection.
---@param l2 integer Last line.
---@param c2 integer Last byte column, inclusive; math.huge for linewise.
---@return string
function M.selected_text(rendered, get_line, l1, c1, l2, c2)
  local ranges = {}
  for l = l1, l2 do
    local info = rendered.line_info[l]
    if info then
      local line = get_line(l)
      local s = math.max(l == l1 and c1 or 1, info.skip + 1)
      local e = math.min(l == l2 and c2 or #line, #line)
      local last = ranges[#ranges]
      if last and last.section == info.section and last.src == info.src then
        if e >= s then
          last.e = e + info.delta
        end
      else
        ranges[#ranges + 1] = { section = info.section, src = info.src, s = s + info.delta, e = e + info.delta }
      end
    end
  end
  local paragraphs, cur, section = {}, nil, nil
  for _, r in ipairs(ranges) do
    if r.section ~= section then
      cur, section = {}, r.section
      paragraphs[#paragraphs + 1] = cur
    end
    local src = rendered.sections[r.section].lines[r.src]
    cur[#cur + 1] = r.e >= r.s and src:sub(r.s, r.e) or ""
  end
  local texts = vim.tbl_map(function(p)
    return vim.trim(table.concat(p, "\n"))
  end, paragraphs)
  texts = vim.tbl_filter(function(t)
    return t ~= ""
  end, texts)
  return table.concat(texts, "\n\n")
end

--- The window to quote into: the one eunoe was opened from, else the
--- previous window, else any other window in the tab page.
---@return integer?
local function quote_target(st, eunoe_win)
  local candidates = { st.prev_win, vim.fn.win_getid(vim.fn.winnr("#")) }
  vim.list_extend(candidates, vim.api.nvim_tabpage_list_wins(0))
  for _, win in ipairs(candidates) do
    if win and win ~= 0 and win ~= eunoe_win and vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if not M.state[buf] and vim.api.nvim_win_get_config(win).relative == "" then
        return win
      end
    end
  end
end

--- Insert `text` as a `>` blockquote at the cursor line of `win`, and
--- move there with the cursor on a blank line right after the quote, ready
--- for a comment. On a line with text, the quote goes below it; a blank
--- cursor line is replaced. Blank lines separate the quote from text
--- above and below.
---@param win integer
---@param text string
function M.insert_quote(win, text)
  local buf = vim.api.nvim_win_get_buf(win)
  if not vim.bo[buf].modifiable then
    return vim.notify("eunoe: the target buffer isn't modifiable", vim.log.levels.WARN)
  end
  local function line(r) -- 1-based; nil outside the buffer
    if r < 1 then
      return nil
    end
    return vim.api.nvim_buf_get_lines(buf, r - 1, r, false)[1]
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  -- Replace rows (from, to] (0-based start, exclusive end in API terms).
  local from, to
  if (line(row) or ""):find("%S") then
    from, to = row, row
  else
    from, to = row - 1, row
  end
  local above, below = line(from), line(to + 1)

  local insert = {}
  if above and above:find("%S") then
    insert[#insert + 1] = ""
  end
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    insert[#insert + 1] = l == "" and ">" or "> " .. l
  end
  insert[#insert + 1] = "" -- the cursor goes here
  local cursor = from + #insert
  if below and below:find("%S") then
    insert[#insert + 1] = ""
  end

  vim.api.nvim_buf_set_lines(buf, from, to, false, insert)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { cursor, 0 })
end

--- Quote the Visual selection of the eunoe buffer into the prompt window.
function M.quote_visual()
  local buf = vim.api.nvim_get_current_buf()
  local st = M.state[buf]
  local mode = vim.fn.mode()
  local v, c = vim.fn.getpos("v"), vim.fn.getpos(".")
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  if not st then
    return vim.notify("eunoe: quoting works in the eunoe split", vim.log.levels.WARN)
  end
  local p1, p2 = v, c
  if p1[2] > p2[2] or (p1[2] == p2[2] and p1[3] > p2[3]) then
    p1, p2 = p2, p1
  end
  local l1, c1, l2, c2 = p1[2], p1[3], p2[2], p2[3]
  local function get_line(l)
    return vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1] or ""
  end
  if mode == "v" then
    -- Include the whole last character (multibyte).
    local last = get_line(l2)
    if c2 <= #last then
      c2 = c2 + vim.str_utf_end(last, c2)
    end
  else
    c1, c2 = 1, math.huge
  end
  local text = M.selected_text(st.rendered, get_line, l1, c1, l2, c2)
  if text == "" then
    return vim.notify("eunoe: nothing to quote in the selection", vim.log.levels.WARN)
  end
  local target = quote_target(st, vim.api.nvim_get_current_win())
  if not target then
    return vim.notify("eunoe: no window to quote into", vim.log.levels.WARN)
  end
  M.insert_quote(target, text)
end

---@param keys table<string, string|false>
local function set_keymaps(buf, handlers, keys)
  local function map(mode, name, rhs, desc)
    local lhs = keys[name]
    if lhs then
      vim.keymap.set(mode, lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
  end
  map("n", "close", handlers.close, "eunoe: close")
  map("n", "next_turn", function()
    M.jump(buf, 1)
  end, "eunoe: next turn")
  map("n", "prev_turn", function()
    M.jump(buf, -1)
  end, "eunoe: previous turn")
  map("n", "reload", handlers.reload, "eunoe: reload")
  map("x", "quote", M.quote_visual, "eunoe: quote into the prompt")
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
---@param opts { name: string, total: integer?, truncate: table|false, wrap: integer|false|nil, width: number, focus: boolean, handlers: table, keys: table? }
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
  set_keymaps(buf, opts.handlers, opts.keys or require("eunoe.config").defaults.keys)

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
