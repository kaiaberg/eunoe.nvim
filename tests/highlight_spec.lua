local h = require("helpers")
local hl = require("eunoe.highlight")

local function get(name)
  return vim.api.nvim_get_hl(0, { name = name })
end

local function hex(n)
  return ("#%06X"):format(n)
end

--- Back to the default dark background, with every group defined fresh.
local function dark()
  vim.o.background = "dark"
  vim.cmd("hi clear")
  vim.api.nvim_exec_autocmds("ColorScheme", {})
end

--- Run `fn` with a `Normal` background, then restore the default one.
local function with_background(bg, fn)
  local old = vim.api.nvim_get_hl(0, { name = "Normal" })
  vim.api.nvim_set_hl(0, "Normal", { bg = bg, fg = "#000000" })
  local ok, err = pcall(fn)
  vim.api.nvim_set_hl(0, "Normal", old)
  dark()
  if not ok then
    error(err, 0)
  end
end

return {
  ["groups are defined, and again after :colorscheme"] = function()
    hl.setup()
    dark()
    h.eq(hex(get("EunoeUser").fg), "#8A93A6", "slate as is on the dark default background")
    h.eq(get("EunoeAgent").link, "Title")
    local group = hl.agent_group("claude", "#D97757")
    h.eq(group, "EunoeAgentClaude")
    h.eq(hex(get(group).fg), "#D97757")
    h.eq(get(group).ctermfg, 173)
    vim.cmd("hi clear")
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    h.eq(hex(get("EunoeUser").fg), "#8A93A6")
    h.eq(hex(get(group).fg), "#D97757")
  end,
  ["readable: the hue stays, the lightness moves to 4.5:1"] = function()
    h.eq(hl.readable("#D97757", "#14161B"), "#D97757", "already readable")
    for _, bg in ipairs({ "#FFFFFF", "#FBF1C7", "#2E3440", "#E0E2EA" }) do
      for _, color in ipairs({ "#D97757", hl.USER_COLOR }) do
        local out = hl.readable(color, bg)
        h.truthy(hl.contrast(out, bg) >= 4.5, ("%s on %s: %s"):format(color, bg, out))
        h.truthy(hl.contrast(out, bg) < 5.2, ("%s on %s moved too far: %s"):format(color, bg, out))
      end
    end
    h.truthy(hl.luminance(hl.readable("#D97757", "#FFFFFF")) < hl.luminance("#D97757"), "darker on white")
    h.truthy(hl.luminance(hl.readable("#D97757", "#2E3440")) > hl.luminance("#D97757"), "lighter on nord")
  end,
  ["on a light background the speaker colors get darker, and follow 'background'"] = function()
    hl.setup()
    dark()
    local group = hl.agent_group("claude", "#D97757")
    with_background("#FFFFFF", function()
      vim.api.nvim_exec_autocmds("OptionSet", { pattern = "background" })
      for _, name in ipairs({ "EunoeUser", group }) do
        h.truthy(hl.contrast(hex(get(name).fg), "#FFFFFF") >= 4.5, name .. " unreadable on white")
      end
    end)
    h.eq(hex(get(group).fg), "#D97757", "back on the dark background")
  end,
  ["themes and users win: eunoe leaves groups it didn't set"] = function()
    hl.setup()
    dark()
    vim.api.nvim_set_hl(0, "EunoeUser", { fg = "#123456" })
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    vim.api.nvim_exec_autocmds("OptionSet", { pattern = "background" })
    h.eq(hex(get("EunoeUser").fg), "#123456")
    vim.cmd("hi clear")
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    h.eq(hex(get("EunoeUser").fg), "#8A93A6", "a cleared group is eunoe's again")
  end,
  ["an agent without a color links to EunoeAgent"] = function()
    local group = hl.agent_group("my-agent", nil)
    h.eq(group, "EunoeAgentMyagent")
    h.eq(get(group).link, "EunoeAgent")
    h.eq(get(hl.agent_group("bad", "orange")).link, "EunoeAgent")
  end,
  ["background: Normal's, or a stand-in for transparent themes"] = function()
    with_background("#FBF1C7", function()
      h.eq(hl.background(), "#FBF1C7")
    end)
    -- Setting 'background' makes the default colorscheme set Normal again,
    -- so clear Normal after it.
    vim.o.background = "light"
    vim.api.nvim_set_hl(0, "Normal", {})
    h.eq(hl.background(), "#FFFFFF")
    vim.o.background = "dark"
    vim.api.nvim_set_hl(0, "Normal", {})
    h.eq(hl.background(), "#1A1A1A")
    dark()
  end,
  ["cterm: 256-color approximations"] = function()
    h.eq(hl.cterm("#000000"), 16)
    h.eq(hl.cterm("#ffffff"), 231)
    h.eq(hl.cterm("#D97757"), 173)
    h.eq(hl.cterm("#5C8FD6"), 68)
  end,
}
