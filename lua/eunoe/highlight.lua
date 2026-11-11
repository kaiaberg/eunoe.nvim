--- Highlight groups. All are defined with `default = true`, so a
--- colorscheme or `nvim_set_hl()` in your config wins. `:colorscheme`
--- clears highlight groups, so they are defined again on `ColorScheme`.
local M = {}

M.ns = vim.api.nvim_create_namespace("eunoe")

--- The default groups. Mid tones, so they read on dark and light
--- backgrounds; `ctermfg` for terminals without true color.
M.groups = {
  --- Your prompts' headings.
  EunoeUser = { fg = "#5C8FD6", ctermfg = 68, bold = true },
  --- The agent's headings, unless its reader has a color.
  EunoeAgent = { link = "Title" },
}

-- Agent groups defined so far, name → reader color (or false).
local agents = {}

local function define(name, spec)
  vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", spec, { default = true }))
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

local function define_agent(group, color)
  if color then
    define(group, { fg = color, ctermfg = M.cterm(color), bold = true })
  else
    define(group, { link = "EunoeAgent" })
  end
end

--- The highlight group for an agent's headings: `EunoeAgent<Name>`
--- (`EunoeAgentClaude`), set from the reader's `color`, or linked to
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
  if agents[group] == nil or agents[group] ~= (color or false) then
    agents[group] = color or false
    define_agent(group, color)
  end
  return group
end

local done = false

--- Define the groups, and again after every `:colorscheme`.
function M.setup()
  if done then
    return
  end
  done = true
  local function all()
    for name, spec in pairs(M.groups) do
      define(name, spec)
    end
    for group, color in pairs(agents) do
      define_agent(group, color or nil)
    end
  end
  all()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("eunoe.highlight", { clear = true }),
    callback = all,
  })
end

return M
