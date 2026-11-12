-- The split's width, rewrapping on resize, zoom, the hint line and
-- auto-open.
local h = require("helpers")
local view = require("eunoe.view")

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

--- Run `fn` with the editor `cols` wide, then restore it.
local function with_columns(cols, fn)
  local old = vim.o.columns
  vim.o.columns = cols
  local ok, err = pcall(fn)
  reset()
  vim.o.columns = old
  if not ok then
    error(err, 0)
  end
end

local function words(n)
  return vim.trim(string.rep("word ", n))
end

-- A long paragraph, a code line wider than any wrap, and a long reply to
-- truncate.
local CODE = "local x = " .. string.rep("y", 140)
local TURNS = {
  { n = 1, prompt = words(60), reply = "```lua\n" .. CODE .. "\n```\n\n" .. words(60) },
  { n = 2, prompt = "short", reply = words(400) },
}

local function show(extra)
  return view.show(
    TURNS,
    vim.tbl_extend("force", {
      name = "eunoe://test/" .. tostring(math.random(1e9)),
      truncate = { chars = 300, open_latest = false },
      wrap = 80,
      width = nil,
      zoom = 0.9,
      hints = true,
      focus = true,
      handlers = { close = view.close, reload = function() end },
      keys = require("eunoe.config").defaults.keys,
    }, extra or {})
  )
end

--- Display width of the widest buffer line in a message (not a heading).
local function widest_text(buf)
  local st = view.state[buf]
  local w = 0
  for lnum in pairs(st.rendered.line_info) do
    local l = st.rendered.lines[lnum]
    if l ~= CODE then
      w = math.max(w, vim.fn.strdisplaywidth(l))
    end
  end
  return w
end

--- What WinResized does (it doesn't fire in `nvim -l`).
local function settle()
  view.on_resized(vim.api.nvim_list_wins())
end

--- The hint line as plain text.
local function hint_text(win)
  local bar = vim.api.nvim_win_call(win, function()
    return vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true }).str
  end)
  return bar
end

return {
  ["split_width: fits the text by default, else a fraction or columns"] = function()
    with_columns(200, function()
      h.eq(view.split_width(nil, 80, true), 83, "wrap + left column + margin")
      h.eq(view.split_width(nil, 80, false), 81, "no left column")
      h.eq(view.split_width(nil, false, true), 80, "no wrap: 40%")
      h.eq(view.split_width(0.5, 80, true), 100)
      h.eq(view.split_width(70, 80, true), 70)
      h.eq(view.split_width(nil, 300, true), 180, "20 columns stay for the other windows")
    end)
    with_columns(90, function()
      h.eq(view.split_width(nil, 80, true), 70)
    end)
  end,
  ["zoom_width: fraction or columns, leaving a strip of 10"] = function()
    with_columns(200, function()
      h.eq(view.zoom_width(0.9), 180)
      h.eq(view.zoom_width(0.99), 190)
      h.eq(view.zoom_width(120), 120)
    end)
  end,
  ["show: the split fits wrap; boxes stop at wrap, code lines aside"] = function()
    with_columns(200, function()
      local win, buf = show()
      h.eq(vim.api.nvim_win_get_width(win), 83)
      h.eq(view.state[buf].wrap, 80)
      h.eq(view.state[buf].box_width, 81)
      h.truthy(widest_text(buf) <= 80, "prose wraps at 80")
    end)
  end,
  ["resize: narrower rewraps to the window, wider never past wrap"] = function()
    with_columns(200, function()
      local win, buf = show()
      vim.api.nvim_win_set_width(win, 50)
      settle()
      h.eq(view.state[buf].wrap, 47)
      h.truthy(widest_text(buf) <= 47, "rewrapped at 47: " .. widest_text(buf))
      vim.api.nvim_win_set_width(win, 120)
      settle()
      h.eq(view.state[buf].wrap, 80)
      h.truthy(widest_text(buf) <= 80)
      h.eq(view.state[buf].box_width, 118, "the box grows toward the code line, up to the window")
    end)
  end,
  ["resize: the cursor stays on its word, open folds stay open"] = function()
    with_columns(200, function()
      local win, buf = show({ mode = "default" })
      local st = view.state[buf]
      -- The second reply is truncated; open it and put the cursor in it.
      local fold = st.rendered.folds[#st.rendered.folds]
      vim.cmd(fold.first .. "foldopen")
      vim.api.nvim_win_set_cursor(win, { fold.first + 1, 12 })
      vim.cmd("normal! zz")
      local function word_at_cursor()
        return vim.fn.expand("<cword>"), vim.api.nvim_win_get_cursor(win)[2]
      end
      -- Source position of the cursor: its section and byte.
      local function source_pos()
        local s = view.state[buf]
        local c = vim.api.nvim_win_get_cursor(win)
        local info = s.rendered.line_info[c[1]]
        return info.section, info.src, c[2] + info.delta
      end
      local before = { source_pos() }
      h.eq(word_at_cursor(), "word")
      vim.api.nvim_win_set_width(win, 50)
      settle()
      h.eq({ source_pos() }, before, "same source position")
      local new = view.state[buf].rendered.folds[#view.state[buf].rendered.folds]
      h.eq(vim.fn.foldclosed(new.first), -1, "the opened fold is still open")
      local first = view.state[buf].rendered.folds[1]
      h.truthy(vim.fn.foldclosed(first.first) ~= -1, "the others stay closed")
    end)
  end,
  ["zoom: wider, prose still at wrap, boxes fit the code; back to the width before"] = function()
    with_columns(200, function()
      local win, buf = show()
      vim.api.nvim_win_set_width(win, 70)
      settle()
      view.toggle_zoom(win)
      h.eq(vim.api.nvim_win_get_width(win), 180)
      local st = view.state[buf]
      h.eq(st.wrap, 80)
      h.truthy(widest_text(buf) <= 80)
      h.eq(st.box_width, #CODE + 1)
      h.eq(view.status(buf).zoomed, true)
      h.eq(vim.b[buf].eunoe_status.zoomed, true)
      view.toggle_zoom(win)
      h.eq(vim.api.nvim_win_get_width(win), 70, "the width before zooming")
      h.eq(view.status(buf).zoomed, false)
    end)
  end,
  ["zoom: resizing by hand ends it"] = function()
    with_columns(200, function()
      local win, buf = show()
      view.toggle_zoom(win)
      vim.api.nvim_win_set_width(win, 100)
      settle()
      h.eq(view.status(buf).zoomed, false)
      view.toggle_zoom(win)
      h.eq(vim.api.nvim_win_get_width(win), 180, "zooms again")
    end)
  end,
  ["zoom: the key, :Eunoe zoom and eunoe.zoom() opening it zoomed"] = function()
    with_columns(200, function()
      local win, buf = show()
      vim.cmd("normal gz")
      h.eq(vim.api.nvim_win_get_width(win), 180)
      vim.cmd("normal gz")
      h.eq(vim.api.nvim_win_get_width(win), 83)
      view.close()
      view.zoom_next = true
      win, buf = show()
      h.eq(vim.api.nvim_win_get_width(win), 180, "opened zoomed")
      h.eq(view.status(buf).zoomed, true)
      view.toggle_zoom(win)
      h.eq(vim.api.nvim_win_get_width(win), 83, "back to the normal width")
    end)
  end,
  ["hints: keys from the config, the mode on, help at the end"] = function()
    with_columns(200, function()
      local win = show()
      local text = hint_text(win)
      h.truthy(text:find("^ o one%-line  O expanded  gz zoom  %]%] %[%[ turns  > quote  q close  R reload"), text)
      h.truthy(text:find("g%? help $"), text)
      view.close()
      local keys = vim.tbl_extend("force", require("eunoe.config").defaults.keys, {
        oneline = "<Tab>",
        reload = false,
        prev_turn = false,
        zoom = "%",
      })
      win = show({ keys = keys })
      text = hint_text(win)
      h.truthy(text:find("<Tab> one-line", 1, true), text)
      h.truthy(text:find("]] turns", 1, true), text)
      h.truthy(text:find("%% zoom"), "a % key shows as itself: " .. text)
      h.truthy(not text:find("reload", 1, true), text)
    end)
  end,
  ["hints: the current mode and zoom are highlighted"] = function()
    with_columns(200, function()
      local win, buf = show()
      local function on()
        local st = view.state[buf]
        local items = view.hint_items(st, win)
        local out = {}
        for _, item in ipairs(items) do
          if item.on then
            out[#out + 1] = item.text
          end
        end
        return out
      end
      h.eq(on(), {})
      view.set_mode(win, "oneline")
      h.eq(on(), { "one-line" })
      view.toggle_zoom(win)
      view.set_mode(win, "expanded")
      h.eq(on(), { "expanded", "zoom" })
      h.truthy(vim.wo[win].winbar:find("eunoe"), "winbar set")
    end)
  end,
  ["hints: narrow windows drop hints from the end, help stays; off with hints = false"] = function()
    with_columns(200, function()
      local win = show()
      vim.api.nvim_win_set_width(win, 40)
      settle()
      local text = hint_text(win)
      h.truthy(text:find("^ o one%-line  O expanded"), text)
      h.truthy(not text:find("close", 1, true), text)
      h.truthy(text:find("g? help", 1, true), text)
      h.truthy(vim.fn.strdisplaywidth(text) <= 40, text)
      view.close()
      win = show({ hints = false })
      h.eq(vim.wo[win].winbar, "")
    end)
  end,
  ["help: g? opens the keys in :help"] = function()
    with_columns(200, function()
      local tmp = vim.fn.tempname()
      vim.fn.mkdir(tmp .. "/doc", "p")
      vim.fn.writefile(vim.fn.readfile(h.root .. "/doc/eunoe.txt"), tmp .. "/doc/eunoe.txt")
      vim.cmd.helptags(tmp .. "/doc")
      vim.opt.rtp:prepend(tmp)
      show()
      vim.cmd("normal g?")
      h.eq(vim.bo.filetype, "help")
      h.truthy(vim.api.nvim_get_current_line():find("*eunoe-keys*", 1, true), vim.api.nvim_get_current_line())
      vim.cmd.helpclose()
      vim.opt.rtp:remove(tmp)
    end)
  end,
  ["auto_open: opens for a parent agent, the cursor stays; quiet otherwise"] = function()
    reset()
    local eunoe, config = require("eunoe"), require("eunoe.config")
    local ctx
    require("eunoe.session").context(function(c)
      ctx = c
    end)
    h.wait(function()
      return ctx ~= nil
    end)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/sessions", "p")
    vim.fn.mkdir(root .. "/projects/p", "p")
    vim.fn.writefile(h.lines("claude/resumed.jsonl"), root .. "/projects/p/abc-123.jsonl")
    local function sessions_file(pid)
      vim.fn.delete(root .. "/sessions", "rf")
      vim.fn.mkdir(root .. "/sessions", "p")
      if pid then
        vim.fn.writefile(
          { vim.json.encode({ pid = pid, sessionId = "abc-123", cwd = ctx.cwd }) },
          ("%s/sessions/%d.json"):format(root, pid)
        )
      end
    end
    local old, notify = vim.env.CLAUDE_CONFIG_DIR, vim.notify
    local notes = {}
    vim.env.CLAUDE_CONFIG_DIR = root
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    local ok, err = pcall(function()
      local function try()
        eunoe._auto_opened = false
        eunoe.auto_open()
        -- Let the lookup finish.
        vim.wait(300, function()
          return view.current() ~= nil
        end, 5)
        return view.current() ~= nil
      end
      config.setup({ view = { focus = true } })
      sessions_file(ctx.chain[1])
      h.eq(try(), false, "off by default")

      config.setup({ view = { auto_open = true, focus = true } })
      local prompt = vim.api.nvim_get_current_win()
      h.eq(try(), true, "Neovim's parent is an agent")
      h.eq(vim.api.nvim_get_current_win(), prompt, "the cursor stays, even with view.focus")
      eunoe._auto_opened = true
      eunoe.auto_open()
      reset()

      -- An agent running in the cwd (here: this Neovim's own pid), not a parent.
      sessions_file(vim.fn.getpid())
      h.eq(try(), false, "only a session by cwd")
      eunoe.open()
      h.wait(function()
        return view.current() ~= nil
      end)
      h.truthy(view.current(), ":Eunoe does find it")
      reset()
      sessions_file(nil)
      h.eq(try(), false, "no session")
      h.eq(notes, {}, "no messages")
    end)
    vim.env.CLAUDE_CONFIG_DIR, vim.notify = old, notify
    config.setup({})
    eunoe._auto_opened = false
    reset()
    if not ok then
      error(err, 0)
    end
  end,
}
