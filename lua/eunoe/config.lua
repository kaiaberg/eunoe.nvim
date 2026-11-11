--- Configuration. eunoe works without `setup()`; these are the defaults.
local M = {}

---@class eunoe.Config
M.defaults = {
  --- How many turns `:Eunoe` shows (newest at the bottom); `:Eunoe all`
  --- shows all of them.
  turns = 10,
  view = {
    --- Width of the split: a fraction of the editor's columns (< 1) or a
    --- number of columns.
    width = 0.4,
    --- Move the cursor into the split when it opens.
    focus = true,
    --- Break lines longer than this many characters into several lines (at
    --- spaces; not in code blocks or tables), so long paragraphs can be
    --- truncated too. `false` keeps lines as they are. Copying with `y`
    --- gets the extra line breaks; quoting uses the original text.
    wrap = 80,
  },
  --- Keys in the eunoe split (buffer-local). `false` leaves a key unmapped.
  keys = {
    close = "q",
    next_turn = "]]",
    prev_turn = "[[",
    reload = "R",
    --- Visual mode: quote the selection into the prompt window.
    quote = ">",
  },
  --- Long prompts and replies show their beginning; the rest goes into a
  --- closed fold. `false` turns truncation off.
  truncate = {
    --- Characters to show before folding the rest. The cut lands at the
    --- end of a line (see `view.wrap`), and never inside a fenced code
    --- block.
    chars = 800,
    --- Separate limits for prompts and replies; nil uses `chars`.
    prompt = nil,
    reply = nil,
    --- Leave the newest reply unfolded (it's the one being answered); its
    --- fold still exists, so `zc` closes it.
    open_latest = true,
  },
}

M.options = vim.deepcopy(M.defaults)

---@param opts table?
function M.setup(opts)
  opts = opts or {}
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  if opts.truncate == false then
    merged.truncate = false
  end
  M.options = merged
end

return M
