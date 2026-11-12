if vim.g.loaded_eunoe then
  return
end
vim.g.loaded_eunoe = true

local MODES = { "default", "oneline", "expanded" }

local subcommands = {
  all = function()
    require("eunoe").open({ all = true })
  end,
  zoom = function()
    require("eunoe").zoom()
  end,
  mode = function(name)
    if not name then
      return vim.notify("eunoe: mode " .. require("eunoe").mode())
    end
    if not vim.tbl_contains(MODES, name) then
      return vim.notify(("eunoe: unknown mode %q (default, oneline, expanded)"):format(name), vim.log.levels.ERROR)
    end
    require("eunoe").mode(name)
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
  fn(cmd.fargs[2])
end, {
  nargs = "*",
  desc = "Show the agent's conversation",
  complete = function(lead, line)
    local words = vim.split(line, "%s+", { trimempty = true })
    local done = #words - (lead == "" and 0 or 1) -- words before the one being typed
    local choices = done == 1 and vim.tbl_keys(subcommands) or (done == 2 and words[2] == "mode" and MODES) or {}
    table.sort(choices)
    return vim.tbl_filter(function(s)
      return s:find(lead, 1, true) == 1
    end, choices)
  end,
})

-- `view.auto_open`: after startup, so setup() in your config has run.
vim.api.nvim_create_autocmd("VimEnter", {
  group = vim.api.nvim_create_augroup("eunoe.auto_open", { clear = true }),
  once = true,
  callback = function()
    require("eunoe").auto_open()
  end,
})

vim.keymap.set("n", "<Plug>(eunoe-toggle)", function()
  require("eunoe").toggle()
end, { desc = "eunoe: toggle the conversation split" })

vim.keymap.set("x", "<Plug>(eunoe-quote)", function()
  require("eunoe.view").quote_visual()
end, { desc = "eunoe: quote the selection into the prompt" })
