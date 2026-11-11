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
    --- One line per message, and back.
    oneline = "o",
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
  --- Icons before the names in the headings (Nerd Font glyphs). `false`
  --- turns them off, e.g. without a Nerd Font.
  icons = {
    --- Your prompts: nf-fa-user.
    user = "\u{f007}",
    --- The agent's replies; nil uses the agent's own icon (Claude Code:
    --- nf-cod-claude), or nf-md-robot for agents without one.
    agent = nil,
  },
}

M.options = vim.deepcopy(M.defaults)

local function whole(v)
  return type(v) == "number" and v >= 1 and v == math.floor(v)
end
local function opt(check, expect)
  return { check = check, expect = expect }
end
local BOOL = opt(function(v)
  return type(v) == "boolean"
end, "true or false")
local LIMIT = opt(function(v)
  return v == nil or whole(v)
end, "a positive whole number")
local ICON = opt(function(v)
  return v == nil or type(v) == "string"
end, "a string")
local KEY = opt(function(v)
  return v == false or (type(v) == "string" and v ~= "")
end, "a key (string) or false")

-- What each option may be. A table with `fields` is a group of options;
-- `or_false` lets the whole group be `false`.
local SCHEMA = {
  turns = opt(whole, "a positive whole number"),
  view = {
    fields = {
      width = opt(function(v)
        return type(v) == "number" and v > 0
      end, "a fraction below 1 or a number of columns"),
      focus = BOOL,
      wrap = opt(function(v)
        return v == false or (whole(v) and v >= 20)
      end, "false or a number of columns (20 or more)"),
    },
  },
  keys = {
    fields = { close = KEY, next_turn = KEY, prev_turn = KEY, reload = KEY, quote = KEY, oneline = KEY },
  },
  truncate = {
    or_false = true,
    fields = { chars = LIMIT, prompt = LIMIT, reply = LIMIT, open_latest = BOOL },
  },
  icons = {
    or_false = true,
    fields = { user = ICON, agent = ICON },
  },
}

--- Problems in user options: wrong types and unknown names.
---@param opts table
---@return string[]
function M.validate(opts)
  local problems = {}
  local function walk(value, schema, path)
    if schema.fields then
      if value == false and schema.or_false then
        return
      end
      if type(value) ~= "table" then
        problems[#problems + 1] = ("%s: expected a table%s, got %s"):format(
          path,
          schema.or_false and " or false" or "",
          vim.inspect(value)
        )
        return
      end
      for k, v in pairs(value) do
        local sub = schema.fields[k]
        local name = path == "" and tostring(k) or (path .. "." .. tostring(k))
        if sub then
          walk(v, sub, name)
        else
          problems[#problems + 1] = ("%s: unknown option"):format(name)
        end
      end
    elseif not schema.check(value) then
      problems[#problems + 1] = ("%s: expected %s, got %s"):format(path, schema.expect, vim.inspect(value))
    end
  end
  walk(opts, { fields = SCHEMA }, "")
  table.sort(problems)
  return problems
end

--- Problems found by the last `setup()`, for `:checkhealth`.
M.problems = {}

---@param opts table?
function M.setup(opts)
  opts = opts or {}
  M.problems = M.validate(opts)
  if #M.problems > 0 then
    vim.notify("eunoe: setup(): " .. table.concat(M.problems, "; "), vim.log.levels.WARN)
  end
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  for _, group in ipairs({ "truncate", "icons" }) do
    if opts[group] == false then
      merged[group] = false
    end
  end
  M.options = merged
end

return M
