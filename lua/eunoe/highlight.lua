--- Highlight groups. A colorscheme or `nvim_set_hl()` in your config
--- wins: eunoe only (re)defines a group that is unset or still holds what
--- eunoe set. The speaker colors are adjusted to the background, so they
--- stay readable on dark and light themes; they are computed again on
--- `ColorScheme` (which also clears all groups) and when 'background'
--- changes.
local M = {}

M.ns = vim.api.nvim_create_namespace("eunoe")

--- Minimum contrast of the speaker colors against the background (the
--- WCAG ratio for normal text).
M.CONTRAST = 4.5

--- Your prompts' color before adjusting: slate gray (Claude Code shows
--- your prompts in gray, the agent in color).
M.USER_COLOR = "#8A93A6"

--- Groups that only link; they follow the colorscheme as is.
M.links = {
  --- The agent's headings, unless its reader has a color.
  EunoeAgent = "Title",
  --- The time on the heading lines.
  EunoeTime = "Comment",
  --- The start of a message in one-line mode.
  EunoeOneline = "Normal",
  --- Closed folds in the eunoe window (it maps `Folded` to this group):
  --- one-line rows look like plain lines.
  EunoeFolded = "Normal",
  --- The "… 1,615 more characters" line of truncated text.
  EunoeTruncated = "Comment",
  --- The hint line at the top of the split ('winbar'; the window maps
  --- `WinBar` and `WinBarNC` to this group).
  EunoeWinBar = "Normal",
  --- The hints' words, keys, and the mode or zoom that's on.
  EunoeHint = "Comment",
  EunoeHintKey = "Special",
  EunoeHintOn = "Title",
}

local function rgb(hex)
  return tonumber(hex:sub(2, 3), 16) / 255, tonumber(hex:sub(4, 5), 16) / 255, tonumber(hex:sub(6, 7), 16) / 255
end

local function to_hex(r, g, b)
  local function c(x)
    return math.floor(math.max(0, math.min(1, x)) * 255 + 0.5)
  end
  return ("#%02X%02X%02X"):format(c(r), c(g), c(b))
end

--- Relative luminance (WCAG).
---@param hex string
---@return number
function M.luminance(hex)
  local function lin(x)
    return x <= 0.03928 and x / 12.92 or ((x + 0.055) / 1.055) ^ 2.4
  end
  local r, g, b = rgb(hex)
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
end

--- Contrast ratio of two colors, 1 to 21.
function M.contrast(a, b)
  local la, lb = M.luminance(a), M.luminance(b)
  if la < lb then
    la, lb = lb, la
  end
  return (la + 0.05) / (lb + 0.05)
end

local function to_hsl(r, g, b)
  local max, min = math.max(r, g, b), math.min(r, g, b)
  local l = (max + min) / 2
  if max == min then
    return 0, 0, l
  end
  local d = max - min
  local s = l > 0.5 and d / (2 - max - min) or d / (max + min)
  local h
  if max == r then
    h = (g - b) / d + (g < b and 6 or 0)
  elseif max == g then
    h = (b - r) / d + 2
  else
    h = (r - g) / d + 4
  end
  return h / 6, s, l
end

local function from_hsl(h, s, l)
  if s == 0 then
    return l, l, l
  end
  local function hue(p, q, t)
    t = t % 1
    if t < 1 / 6 then
      return p + (q - p) * 6 * t
    elseif t < 1 / 2 then
      return q
    elseif t < 2 / 3 then
      return p + (q - p) * (2 / 3 - t) * 6
    end
    return p
  end
  local q = l < 0.5 and l * (1 + s) or l + s - l * s
  local p = 2 * l - q
  return hue(p, q, h + 1 / 3), hue(p, q, h), hue(p, q, h - 1 / 3)
end

--- `color` with its lightness moved until it has `target` contrast
--- against `bg`: darker on light backgrounds, lighter on dark ones. The
--- hue stays, so Claude's orange stays orange.
---@param color string `#rrggbb`
---@param bg string `#rrggbb`
---@param target number?
---@return string
function M.readable(color, bg, target)
  target = target or M.CONTRAST
  if M.contrast(color, bg) >= target then
    return color:upper()
  end
  local h, s, l = to_hsl(rgb(color))
  local step = M.luminance(bg) > 0.18 and -0.01 or 0.01
  local out = color
  while l > 0 and l < 1 do
    l = l + step
    out = to_hex(from_hsl(h, s, l))
    if M.contrast(out, bg) >= target then
      break
    end
  end
  return out
end

--- The editor background: `Normal`'s, or for transparent themes a
--- stand-in from 'background'.
---@return string
function M.background()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  if normal.bg then
    return ("#%06X"):format(normal.bg)
  end
  return vim.o.background == "light" and "#FFFFFF" or "#1A1A1A"
end

--- 256-color approximation of a `#rrggbb` color (the 6×6×6 cube).
---@param hex string
---@return integer
function M.cterm(hex)
  local function level(c)
    -- The cube's levels: 0, 95, 135, 175, 215, 255.
    if c < 48 then
      return 0
    elseif c < 115 then
      return 1
    end
    return math.min(5, math.floor((c - 35) / 40))
  end
  local r, g, b = tonumber(hex:sub(2, 3), 16), tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16)
  return 16 + 36 * level(r) + 6 * level(g) + level(b)
end

-- What eunoe last set per group (as nvim_get_hl() returns it), to tell
-- its own definitions from a theme's or the user's.
local ours = {}

--- Define `name` unless someone else did: it must be unset or still hold
--- what eunoe set last.
local function own(name, spec)
  local cur = vim.api.nvim_get_hl(0, { name = name })
  if next(cur) ~= nil and not vim.deep_equal(cur, ours[name]) then
    return
  end
  vim.api.nvim_set_hl(0, name, spec)
  ours[name] = vim.api.nvim_get_hl(0, { name = name })
end

--- A bold speaker color, readable on the current background.
local function speaker(name, color)
  local fg = M.readable(color, M.background())
  own(name, { fg = fg, ctermfg = M.cterm(fg), bold = true })
end

-- Agent groups defined so far, name → reader color (or false).
local agents = {}

local function define_agent(group, color)
  if color then
    speaker(group, color)
  else
    own(group, { link = "EunoeAgent" })
  end
end

--- The highlight group for an agent's headings: `EunoeAgent<Name>`
--- (`EunoeAgentClaude`), from the reader's `color`, or linked to
--- `EunoeAgent` when it has none.
---@param reader_name string
---@param color string? `#rrggbb`
---@return string
function M.agent_group(reader_name, color)
  local id = reader_name:gsub("[^%w]", "")
  local group = "EunoeAgent" .. id:sub(1, 1):upper() .. id:sub(2)
  if type(color) ~= "string" or not color:match("^#%x%x%x%x%x%x$") then
    color = nil
  end
  if agents[group] ~= (color or false) then
    agents[group] = color or false
    define_agent(group, color)
  end
  return group
end

--- Define (or update) all groups.
function M.refresh()
  for name, target in pairs(M.links) do
    own(name, { link = target })
  end
  speaker("EunoeUser", M.USER_COLOR)
  for group, color in pairs(agents) do
    define_agent(group, color or nil)
  end
end

local done = false

--- Define the groups, and again after every `:colorscheme` and change of
--- 'background'.
function M.setup()
  if done then
    return
  end
  done = true
  M.refresh()
  local group = vim.api.nvim_create_augroup("eunoe.highlight", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = M.refresh })
  vim.api.nvim_create_autocmd("OptionSet", { group = group, pattern = "background", callback = M.refresh })
end

return M
