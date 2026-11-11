local h = require("helpers")
local hl = require("eunoe.highlight")

local function get(name)
  return vim.api.nvim_get_hl(0, { name = name })
end

return {
  ["groups are defined, and again after :colorscheme"] = function()
    hl.setup()
    h.eq(get("EunoeUser").fg, 0x5C8FD6)
    h.eq(get("EunoeAgent").link, "Title")
    local group = hl.agent_group("claude", "#D97757")
    h.eq(group, "EunoeAgentClaude")
    h.eq(get(group).fg, 0xD97757)
    h.eq(get(group).ctermfg, 173)
    vim.cmd("hi clear")
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    h.eq(get("EunoeUser").fg, 0x5C8FD6)
    h.eq(get(group).fg, 0xD97757)
  end,
  ["user highlights win over the defaults"] = function()
    hl.setup()
    vim.api.nvim_set_hl(0, "EunoeUser", { fg = "#123456" })
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    h.eq(get("EunoeUser").fg, 0x123456)
    vim.api.nvim_set_hl(0, "EunoeUser", {})
    vim.cmd("hi clear")
    vim.api.nvim_exec_autocmds("ColorScheme", {})
  end,
  ["an agent without a color links to EunoeAgent"] = function()
    local group = hl.agent_group("my-agent", nil)
    h.eq(group, "EunoeAgentMyagent")
    h.eq(get(group).link, "EunoeAgent")
    h.eq(get(hl.agent_group("bad", "orange")).link, "EunoeAgent")
  end,
  ["cterm: 256-color approximations"] = function()
    h.eq(hl.cterm("#000000"), 16)
    h.eq(hl.cterm("#ffffff"), 231)
    h.eq(hl.cterm("#D97757"), 173)
    h.eq(hl.cterm("#5C8FD6"), 68)
  end,
}
