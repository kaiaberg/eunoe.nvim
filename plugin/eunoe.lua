if vim.g.loaded_eunoe then
  return
end
vim.g.loaded_eunoe = true

local subcommands = {
  all = function()
    require("eunoe").open({ all = true })
  end,
}

vim.api.nvim_create_user_command("Eunoe", function(cmd)
  local sub = cmd.fargs[1]
  if not sub then
    return require("eunoe").toggle()
  end
  local fn = subcommands[sub]
  if not fn then
    return vim.notify(("eunoe: unknown subcommand %q"):format(sub), vim.log.levels.ERROR)
  end
  fn()
end, {
  nargs = "?",
  desc = "Show the agent's conversation",
  complete = function(lead)
    return vim.tbl_filter(function(s)
      return s:find(lead, 1, true) == 1
    end, vim.tbl_keys(subcommands))
  end,
})

vim.keymap.set("n", "<Plug>(eunoe-toggle)", function()
  require("eunoe").toggle()
end, { desc = "eunoe: toggle the conversation split" })
