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
---@field icon_col integer? 0-based byte column of the speaker's icon (virtual text).
---@field icon_text string? The icon's virtual text, with its space.
---@field last integer Last line of the message fold (the blank line after the message included).
---@field section integer Index into `sections`.
---@field time string? ISO timestamp shown on the heading (the prompt's, or the reply's without a prompt).

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

---@class eunoe.HeadingOpts
---@field number boolean? The turn number (default true).
---@field separator boolean? `·` after the number (default true).
---@field names boolean? The speaker's name (default true).
---@field time boolean? The time, right-aligned (default true).
---@field pad boolean? Pad numbers and names in one-line mode, so messages line up (default true).

--- The pieces of a heading, in order: number, separator, icon, name.
--- Missing ones are left out; the separator only stands between the
--- number and something after it.
---@param n integer
---@param name string?
---@param icon string|false?
---@param h eunoe.HeadingOpts
---@param pad { number: integer?, name: integer? }? Widths to pad to.
---@return { text: string, icon: boolean? }[]
function M.heading_pieces(n, name, icon, h, pad)
  pad = pad or {}
  local pieces = {}
  if h.number ~= false then
    local num = tostring(n)
    pieces[1] = { text = string.rep(" ", (pad.number or 0) - #num) .. num }
  end
  local has_icon = type(icon) == "string" and icon ~= ""
  local has_name = h.names ~= false and type(name) == "string" and name ~= ""
  if h.separator ~= false and #pieces > 0 and (has_icon or has_name) then
    pieces[#pieces + 1] = { text = "·" }
  end
  if has_icon then
    pieces[#pieces + 1] = { text = icon, icon = true }
  end
  if has_name then
    pieces[#pieces + 1] = { text = name .. string.rep(" ", (pad.name or 0) - width_of(name)) }
  end
  return pieces
end

--- A heading's buffer line, without the icon, which is drawn as virtual
--- text: where it goes and its text (with the space that separates it).
---@return string line, integer? icon_col, string? icon_text
function M.heading_line(n, name, icon, h)
  local before, after, icon_piece = {}, {}, nil
  for _, p in ipairs(M.heading_pieces(n, name, icon, h)) do
    if p.icon then
      icon_piece = p.text
    elseif icon_piece then
      after[#after + 1] = p.text
    else
      before[#before + 1] = p.text
    end
  end
  local head, tail = table.concat(before, " "), table.concat(after, " ")
  local line = head .. ((head ~= "" and tail ~= "") and " " or "") .. tail
  if not icon_piece then
    return line
  end
  if tail ~= "" then
    return line, #line - #tail, icon_piece .. " "
  end
  return line, #line, (line ~= "" and " " or "") .. icon_piece
end

--- Whether a message's first line would merge with the heading line
--- above it into other Markdown: `---`/`===` would make the heading a
--- setext heading, indented code and ordered lists not starting at 1
--- would continue its paragraph. Those messages get a blank line after
--- the heading.
---@param first string?
---@return boolean
local function merges(first)
  if not first then
    return false
  end
  return first:match("^ ? ? ?%-+%s*$") ~= nil
    or first:match("^ ? ? ?=+%s*$") ~= nil
    or first:match("^    ") ~= nil
    or first:match("^\t") ~= nil
    or (first:match("^ ? ? ?(%d+)[.)]%s") or "1") ~= "1"
end

--- Render turns into lines, with folds for long sections.
---@param turns eunoe.Turn[]
---@param opts { truncate: table|false, total: integer?, wrap: integer|false|nil, agent: string?, heading: eunoe.HeadingOpts?, icons: { prompt: string|false?, reply: string|false? }? }
---@return eunoe.Rendered
function M.render(turns, opts)
  local hopts = opts.heading or {}
  local icons = opts.icons or {}
  local names = { prompt = "You", reply = opts.agent or "Agent" }
  local out = { lines = {}, folds = {}, headings = {}, sections = {}, line_info = {}, names = names, max_n = 0 }
  local lines = out.lines
  local trunc = opts.truncate
  local function add(l)
    lines[#lines + 1] = l
  end
  local function section(turn, role, text, latest, time)
    local line, icon_col, icon_text = M.heading_line(turn.n, names[role], icons[role], hopts)
    add(line)
    local heading =
      { line = #lines, turn = turn.n, role = role, icon_col = icon_col, icon_text = icon_text, time = time }
    out.headings[#out.headings + 1] = heading
    out.max_n = math.max(out.max_n, turn.n)
    local source = vim.split(text, "\n", { plain = true })
    local body, info = M.wrap(source, opts.wrap)
    if merges(body[1]) then
      add("")
    end
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
    heading.section = #out.sections
    heading.last = #lines
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
      section(turn, "prompt", turn.prompt, false, turn.time)
    end
    local reply = turn.reply or "_(no reply)_"
    if turn.interrupted then
      reply = reply .. "\n\n_(interrupted)_"
    end
    section(turn, "reply", reply, latest, not turn.prompt and turn.time or nil)
  end
  -- Drop the trailing blank line.
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  for _, hd in ipairs(out.headings) do
    hd.last = math.min(hd.last, #lines)
  end
  return out
end

-- Per-buffer state: rendered data, keyed by buffer number.
M.state = {}

local function group(n)
  local s = tostring(n)
  return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

--- A message's text as one line: whitespace collapsed, code fences and
--- leading Markdown markers (`#`, `>`) left out.
---@param lines string[]
---@return string
function M.flatten(lines)
  local parts = {}
  for _, line in ipairs(lines) do
    if not is_fence(line) then
      local t = vim.trim(line):gsub("^#+%s+", ""):gsub("^>[>%s]*", "")
      if t ~= "" then
        parts[#parts + 1] = t
      end
    end
  end
  return (table.concat(parts, " "):gsub("%s+", " "))
end

--- Cut `text` to `width` display columns, with "…" when it's cut.
local function clip(text, width)
  if width_of(text) <= width then
    return text
  end
  if width < 1 then
    return ""
  end
  local n = vim.fn.strchars(text)
  -- Cut by characters until it fits; wide characters can take two columns.
  local keep = math.min(n, width - 1)
  while keep > 0 and width_of(vim.fn.strcharpart(text, 0, keep)) > width - 1 do
    keep = keep - 1
  end
  return vim.trim(vim.fn.strcharpart(text, 0, keep)) .. "…"
end

--- The closed message fold, in one-line mode: the heading with its icon
--- and color, then the start of the message.
---@param st table
---@param hd eunoe.Heading
---@param width integer Columns for the whole line.
---@return [string, string][]
function M.message_line(st, hd, width)
  local sp = st.speakers[hd.role]
  local h = st.heading or {}
  local r = st.rendered
  local pad
  if h.pad ~= false then
    pad = { number = #tostring(r.max_n), name = math.max(width_of(r.names.prompt), width_of(r.names.reply)) }
  end
  local pieces = vim.tbl_map(function(p)
    return p.text
  end, M.heading_pieces(hd.turn, r.names[hd.role], sp.icon, h, pad))
  local chunks, used = {}, 0
  local function push(text, hl)
    chunks[#chunks + 1] = { text, hl }
    used = used + width_of(text)
  end
  push(table.concat(pieces, " "), sp.hl)
  -- Leave room for the time, drawn right-aligned over the row.
  local clock = h.time ~= false and M.clock(hd.time)
  if clock then
    width = width - width_of(clock) - 1
  end
  local text = M.flatten(st.rendered.sections[hd.section].lines)
  if text ~= "" and width - used > 4 then
    push("  " .. clip(text, width - used - 2), "EunoeOneline")
  end
  return chunks
end

--- Fold text: a message in one-line mode, or how much a truncation fold
--- hides.
function M.foldtext()
  local st = M.state[vim.api.nvim_get_current_buf()]
  local start = vim.v.foldstart
  local hd = st and st.heading_at[start]
  if hd then
    local width = vim.api.nvim_win_get_width(0)
    if st.wrap then
      width = math.min(width, st.wrap)
    end
    return M.message_line(st, hd, width)
  end
  local fold = st and st.fold_at[start]
  if not fold then
    return vim.fn.foldtext()
  end
  return { { ("… %s more characters (za to expand)"):format(group(fold.chars)), "EunoeTruncated" } }
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

--- The modes are fold levels: one line per message, the default
--- (messages open, long text folded), everything open.
M.ONELINE, M.DEFAULT, M.EXPANDED = 0, 1, 2
M.MODES = { oneline = M.ONELINE, default = M.DEFAULT, expanded = M.EXPANDED }
M.MODE_ORDER = { "oneline", "default", "expanded" }

--- The mode of a fold level (`zr` can go past 2: still expanded).
---@param level integer
---@return "oneline"|"default"|"expanded"
function M.mode_of(level)
  if level <= M.ONELINE then
    return "oneline"
  elseif level == M.DEFAULT then
    return "default"
  end
  return "expanded"
end

-- The fold level kept across reloads and reopening; nil until the mode
-- is first changed, so `view.mode` decides.
M.level = nil
-- The mode a toggle goes back to.
local previous = "default"

--- Set the fold level (the mode) of the eunoe window. In the default mode
--- the newest reply's truncation fold is opened (`truncate.open_latest`).
---@param win integer
---@param level integer
function M.set_level(win, level)
  local st = M.state[vim.api.nvim_win_get_buf(win)]
  vim.wo[win].foldlevel = level
  M.level = level
  if st and level == M.DEFAULT and st.open_latest then
    vim.api.nvim_win_call(win, function()
      for _, f in ipairs(st.rendered.folds) do
        if f.latest then
          vim.cmd(("silent! %dfoldopen"):format(f.first))
        end
      end
    end)
  end
end

--- Scroll `win` so that its lines fill the window, with as many as fit
--- above the end of the buffer, keeping the cursor visible. Without this,
--- one-line mode at the end of the buffer shows one line and empty space.
local function fill(win)
  vim.api.nvim_win_call(win, function()
    local height = vim.api.nvim_win_get_height(win)
    -- The highest top line that still shows the end of the buffer.
    local lnum, rows, top = vim.fn.line("$"), 0, nil
    while lnum >= 1 do
      local start = vim.fn.foldclosed(lnum)
      lnum = start ~= -1 and start or lnum
      rows = rows + vim.api.nvim_win_text_height(win, { start_row = lnum - 1, end_row = lnum - 1 }).all
      if rows > height then
        break
      end
      top, lnum = lnum, lnum - 1
    end
    local view = vim.fn.winsaveview()
    if top and top < view.topline then
      -- The cursor stays visible: it was below the old top line.
      vim.fn.winrestview({ topline = top })
    end
  end)
end

--- The mode of the eunoe window.
---@param win integer
---@return "oneline"|"default"|"expanded"
function M.mode(win)
  return M.mode_of(vim.wo[win].foldlevel)
end

--- The heading of the message at a line: the last one at or above it.
---@param rendered eunoe.Rendered
---@param lnum integer
---@return eunoe.Heading?
function M.heading_at(rendered, lnum)
  local hs = rendered.headings
  local lo, hi, found = 1, #hs, nil
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if hs[mid].line <= lnum then
      found, lo = hs[mid], mid + 1
    else
      hi = mid - 1
    end
  end
  return found
end

---@class eunoe.Status
---@field buf integer The eunoe buffer.
---@field agent string The agent's display name ("Claude Code").
---@field reader string The reader's name ("claude").
---@field session string The session id.
---@field turns integer Turns shown.
---@field total integer Turns in the session.
---@field mode "oneline"|"default"|"expanded"
---@field turn integer? Turn at the cursor.
---@field role "prompt"|"reply"? Message at the cursor.
---@field speaker string? Its speaker's name ("You", "Claude").
---@field loaded integer When the session was read (seconds since the epoch).

--- Status data of an eunoe buffer, computed now.
---@param buf integer
---@return eunoe.Status?
function M.status(buf)
  local st = M.state[buf]
  if not st then
    return nil
  end
  local win = find_win(buf)
  local session = st.session or {}
  local hd = win and M.heading_at(st.rendered, vim.api.nvim_win_get_cursor(win)[1])
  return {
    buf = buf,
    agent = session.label or session.reader or "Agent",
    reader = session.reader or "",
    session = session.id or "",
    turns = st.turns,
    total = st.total,
    mode = win and M.mode(win) or M.mode_of(M.level or M.MODES[st.mode] or M.DEFAULT),
    turn = hd and hd.turn,
    role = hd and hd.role,
    speaker = hd and st.rendered.names[hd.role],
    loaded = st.loaded,
  }
end

--- Refresh `b:eunoe_status` and fire `User EunoeStatus` when it changed.
---@param buf integer
function M.update_status(buf)
  local status = M.status(buf)
  if not status or vim.deep_equal(vim.b[buf].eunoe_status, status) then
    return
  end
  vim.b[buf].eunoe_status = status
  vim.api.nvim_exec_autocmds("User", { pattern = "EunoeStatus", modeline = false, data = status })
end

--- Switch the eunoe window to a mode. The cursor stays on its message:
--- one-line mode fills the window, the other modes put the message at
--- the top.
---@param win integer
---@param name "oneline"|"default"|"expanded"
function M.set_mode(win, name)
  local before = M.mode(win)
  if before ~= name then
    previous = before
  end
  M.set_level(win, M.MODES[name])
  if name == "oneline" then
    fill(win)
  else
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! zt")
    end)
  end
  M.update_status(vim.api.nvim_win_get_buf(win))
end

--- Switch to a mode, or back to the mode before it when it's on.
---@param win integer?
---@param name "oneline"|"expanded"
function M.toggle_mode(win, name)
  win = win or vim.api.nvim_get_current_win()
  if M.mode(win) == name then
    M.set_mode(win, previous ~= name and previous or "default")
  else
    M.set_mode(win, name)
  end
end

--- One line per message, and back.
---@param win integer?
function M.toggle_oneline(win)
  M.toggle_mode(win, "oneline")
end

--- The next mode: one-line → default → expanded → one-line.
---@param win integer?
function M.cycle_mode(win)
  win = win or vim.api.nvim_get_current_win()
  local cur = M.mode(win)
  for i, name in ipairs(M.MODE_ORDER) do
    if name == cur then
      return M.set_mode(win, M.MODE_ORDER[i % #M.MODE_ORDER + 1])
    end
  end
end

local function apply_folds(win, st)
  vim.api.nvim_win_call(win, function()
    vim.cmd("silent! normal! zE")
    -- Truncation folds first: an Ex range inside a closed fold would
    -- grow to the whole fold. The message folds then wrap around them.
    for _, f in ipairs(st.rendered.folds) do
      vim.cmd(("%d,%dfold"):format(f.first, f.last))
    end
    for _, hd in ipairs(st.rendered.headings) do
      vim.cmd(("%d,%dfold"):format(hd.line, hd.last))
    end
  end)
  M.set_level(win, M.level or M.MODES[st.mode] or M.DEFAULT)
end

--- Default icons: nf-md-robot for agents without their own.
M.ROBOT = "\u{f06a9}"

---@class eunoe.Speaker
---@field icon string|false? Icon before the name; false or nil for none.
---@field hl string Highlight group of the heading line.

--- Seconds since the epoch for an ISO 8601 UTC timestamp
--- (`2026-11-11T09:30:00.123Z`), or nil.
---@param iso string?
---@return integer?
function M.epoch(iso)
  local y, mo, d, hh, mm, ss = tostring(iso):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  -- os.time() reads the table as local time; shift by the UTC offset at
  -- that moment.
  local t = os.time({ year = y, month = mo, day = d, hour = hh, min = mm, sec = ss, isdst = false })
  local utc = os.date("!*t", t)
  utc.isdst = false
  return t + (t - os.time(utc))
end

--- A timestamp as local time: `09:30` today, `Nov 10 09:30` before.
---@param iso string?
---@param now integer? Seconds since the epoch (for tests).
---@return string?
function M.clock(iso, now)
  local t = M.epoch(iso)
  if not t then
    return nil
  end
  if os.date("%Y-%m-%d", t) == os.date("%Y-%m-%d", now or os.time()) then
    return os.date("%H:%M", t)
  end
  return os.date("%b %d %H:%M", t)
end

---@class eunoe.Decorations
---@field bar string|false? Character in the sign column next to each message.
---@field time boolean? The time on the heading lines.

--- Color the headings and put the speakers' icons before their names, the
--- time at the end of the heading line, and a colored bar next to every
--- line of a message.
---@param buf integer
---@param rendered eunoe.Rendered
---@param speakers { prompt: eunoe.Speaker, reply: eunoe.Speaker }
---@param deco eunoe.Decorations?
function M.decorate(buf, rendered, speakers, deco)
  deco = deco or {}
  local ns = require("eunoe.highlight").ns
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(rendered.headings) do
    local sp = speakers[h.role]
    local row = h.line - 1
    local section = rendered.sections[h.section]
    if type(deco.bar) == "string" and deco.bar ~= "" and section then
      for l = h.line, section.last do
        vim.api.nvim_buf_set_extmark(buf, ns, l - 1, 0, { sign_text = deco.bar, sign_hl_group = sp.hl, priority = 10 })
      end
    end
    local clock = deco.time ~= false and M.clock(h.time)
    if clock then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        virt_text = { { clock, "EunoeTime" } },
        virt_text_pos = "right_align",
        priority = 200,
      })
    end
    -- Above Treesitter's colors (priority 100).
    local len = #rendered.lines[h.line]
    if len > 0 then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = len, hl_group = sp.hl, priority = 200 })
    end
    if h.icon_col then
      vim.api.nvim_buf_set_extmark(buf, ns, row, h.icon_col, {
        virt_text = { { h.icon_text, sp.hl } },
        virt_text_pos = "inline",
        priority = 200,
      })
    end
  end
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
  wo.winhighlight = "Folded:EunoeFolded"
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
  map("n", "oneline", function()
    M.toggle_mode(nil, "oneline")
  end, "eunoe: one line per message, and back")
  map("n", "expanded", function()
    M.toggle_mode(nil, "expanded")
  end, "eunoe: everything open, and back")
  map("n", "cycle", function()
    M.cycle_mode()
  end, "eunoe: next mode")
  -- Fold-level commands change the mode without an event: run them as
  -- usual, then refresh the status.
  for _, z in ipairs({ "zR", "zM", "zr", "zm" }) do
    vim.keymap.set("n", z, function()
      vim.cmd("normal! " .. (vim.v.count > 0 and vim.v.count or "") .. z)
      M.update_status(buf)
    end, { buffer = buf, silent = true, desc = "eunoe: " .. z .. " (and refresh the status)" })
  end
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
  if vim.wo[win].foldlevel == M.ONELINE then
    fill(win)
  end
end

--- Show rendered turns in the eunoe split, creating it if needed.
---@param turns eunoe.Turn[]
---@param opts { session: { reader: string, id: string, label: string? }?, mode: string?, name: string, total: integer?, truncate: table|false, wrap: integer|false|nil, width: number, focus: boolean, handlers: table, keys: table?, agent: string?, speakers: { prompt: eunoe.Speaker, reply: eunoe.Speaker }?, bar: string|false?, heading: eunoe.HeadingOpts? }
---@return integer win, integer buf
function M.show(turns, opts)
  local win, buf = M.current()
  local has_bar = type(opts.bar) == "string" and opts.bar ~= ""
  -- Wrap at `view.wrap`, or narrower when the window is: lines Neovim
  -- wraps again are hard to read.
  local wrap = opts.wrap
  if wrap then
    local cols = (win and vim.api.nvim_win_get_width(win) or width(opts.width)) - (has_bar and 2 or 0) - 1
    wrap = math.max(20, math.min(wrap, cols))
  end
  local speakers = opts.speakers or {
    prompt = { hl = "EunoeUser" },
    reply = { hl = "EunoeAgent" },
  }
  local rendered = M.render(turns, {
    truncate = opts.truncate,
    total = opts.total,
    wrap = wrap,
    agent = opts.agent,
    heading = opts.heading,
    icons = { prompt = speakers.prompt.icon, reply = speakers.reply.icon },
  })
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
    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = buf,
      callback = function()
        M.update_status(buf)
      end,
    })
  end
  pcall(vim.api.nvim_buf_set_name, buf, opts.name)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rendered.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  require("eunoe.highlight").setup()

  local fold_at, heading_at = {}, {}
  for _, f in ipairs(rendered.folds) do
    fold_at[f.first] = f
  end
  for _, hd in ipairs(rendered.headings) do
    heading_at[hd.line] = hd
  end
  if win then
    -- Keep the mode the user is in (`o`, `zM`, `zR` …) across a reload.
    M.level = vim.wo[win].foldlevel
  end
  local old = M.state[buf]
  local st = {
    -- A reload keeps the window eunoe was opened from (for quoting).
    prev_win = old and old.prev_win,
    rendered = rendered,
    fold_at = fold_at,
    heading_at = heading_at,
    speakers = speakers,
    heading = opts.heading,
    mode = opts.mode,
    session = opts.session,
    turns = #turns,
    total = math.max(opts.total or 0, #turns),
    loaded = os.time(),
    wrap = wrap,
    open_latest = opts.truncate and opts.truncate.open_latest,
  }
  M.state[buf] = st
  M.decorate(buf, rendered, speakers, { bar = opts.bar, time = (opts.heading or {}).time })
  set_keymaps(buf, opts.handlers, opts.keys or require("eunoe.config").defaults.keys)

  local prev = vim.api.nvim_get_current_win()
  if not win then
    win = vim.api.nvim_open_win(buf, false, { split = "right", win = -1, width = width(opts.width) })
    st.prev_win = prev
  end
  set_win_options(win)
  vim.wo[win].signcolumn = has_bar and "yes:1" or "no"
  apply_folds(win, st)
  place_cursor(win, st)
  if opts.focus then
    vim.api.nvim_set_current_win(win)
  end
  M.update_status(buf)
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
  M.level = vim.wo[win].foldlevel
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
