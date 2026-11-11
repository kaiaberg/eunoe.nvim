local h = require("helpers")
local config = require("eunoe.config")
local readers = require("eunoe.readers")

--- Run the health check and collect what it reports: { kind, msg }.
local function run()
  local out = {}
  local saved = {}
  for _, kind in ipairs({ "start", "ok", "info", "warn", "error" }) do
    saved[kind] = vim.health[kind]
    vim.health[kind] = function(msg)
      out[#out + 1] = { kind = kind, msg = msg }
    end
  end
  local ok, err = pcall(require("eunoe.health").check)
  for kind, fn in pairs(saved) do
    vim.health[kind] = fn
  end
  if not ok then
    error(err, 0)
  end
  return out
end

--- The first report of `kind` whose message matches `pattern`.
local function has(out, kind, pattern)
  for _, r in ipairs(out) do
    if r.kind == kind and r.msg:find(pattern) then
      return r
    end
  end
  error(("no %s matching %q in:\n%s"):format(kind, pattern, vim.inspect(out)), 2)
end

local function no(out, kind)
  for _, r in ipairs(out) do
    if r.kind == kind then
      error(("unexpected %s: %s"):format(kind, r.msg), 2)
    end
  end
end

--- A fake Claude config dir whose sessions file points at this process's
--- real parent, with the given transcript lines.
local function fake_claude(transcript)
  local session = require("eunoe.session")
  local ctx = session.context_sync()
  local ppid = ctx.chain[1]
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/sessions", "p")
  vim.fn.mkdir(root .. "/projects/p", "p")
  vim.fn.writefile({
    vim.json.encode({
      pid = ppid,
      sessionId = "hc-1",
      cwd = ctx.cwd,
      procStart = ctx.procs[ppid].start,
      version = "9.9.9",
    }),
  }, ("%s/sessions/%d.json"):format(root, ppid))
  if transcript then
    vim.fn.writefile(transcript, root .. "/projects/p/hc-1.jsonl")
  end
  return root
end

local function with_env(root, fn)
  local old = vim.env.CLAUDE_CONFIG_DIR
  vim.env.CLAUDE_CONFIG_DIR = root
  readers._reset()
  local ok, err = pcall(fn)
  vim.env.CLAUDE_CONFIG_DIR = old
  readers._reset()
  config.setup({})
  if not ok then
    error(err, 0)
  end
end

return {
  ["validate: defaults and partial options are fine"] = function()
    h.eq(config.validate({}), {})
    h.eq(config.validate(vim.deepcopy(config.defaults)), {})
    h.eq(config.validate({ truncate = false, view = { wrap = false }, keys = { quote = false } }), {})
    h.eq(config.validate({ icons = false }), {})
    h.eq(config.validate({ icons = { agent = "A" } }), {})
    h.eq(config.validate({ icons = { user = 1 } }), { "icons.user: expected a string, got 1" })
    config.setup({ icons = false })
    h.eq(config.options.icons, false)
    config.setup({})
  end,
  ["validate: wrong types and unknown names"] = function()
    h.eq(config.validate({ turns = 0, view = { wrap = 10, size = 3 }, trunacte = {}, keys = { quote = 1 } }), {
      "keys.quote: expected a key (string) or false, got 1",
      "trunacte: unknown option",
      "turns: expected a positive whole number, got 0",
      "view.size: unknown option",
      "view.wrap: expected false or a number of columns (20 or more), got 10",
    })
    h.eq(config.validate({ truncate = 5, view = false }), {
      "truncate: expected a table or false, got 5",
      "view: expected a table, got false",
    })
  end,
  ["setup: warns about problems and keeps them for :checkhealth"] = function()
    local notify, got = vim.notify, nil
    vim.notify = function(msg, level)
      got = { msg = msg, level = level }
    end
    local ok, err = pcall(function()
      config.setup({ trunacte = {} })
      h.eq(got.level, vim.log.levels.WARN)
      h.truthy(got.msg:find("trunacte: unknown option", 1, true), got.msg)
      local out = run()
      has(out, "warn", "setup%(%): trunacte: unknown option")
    end)
    vim.notify = notify
    config.setup({})
    if not ok then
      error(err, 0)
    end
  end,
  ["a healthy session: turns, version, known record types"] = function()
    with_env(fake_claude(h.lines("claude/resumed.jsonl")), function()
      local out = run()
      has(out, "ok", "^`ps` works%. Neovim's ancestors: ")
      has(out, "ok", "^claude · Claude Code %(built in%)")
      has(out, "ok", "^1 sessions file%(s%)")
      has(out, "ok", "^Claude Code session hc%-1, pid %d+ %(Neovim was started from it%)")
      has(out, "info", "^Claude Code 9%.9%.9 %(eunoe was last checked against ")
      has(out, "ok", "^2 turn%(s%)")
      has(out, "ok", "^All record types are known")
      no(out, "warn")
      no(out, "error")
    end)
  end,
  ["format changes show up as warnings"] = function()
    local lines = h.lines("claude/resumed.jsonl")
    lines[#lines + 1] = '{"type":"brand-new-record"}'
    lines[#lines + 1] = "not json"
    with_env(fake_claude(lines), function()
      local out = run()
      has(out, "warn", "^Records of types eunoe doesn't know: brand%-new%-record %(1%)")
      has(out, "warn", "^1 line%(s%) of the transcript aren't valid JSON")
    end)
    with_env(fake_claude({ '{"type":"user","uuid":"u","message":{"content":[{"type":"something-new"}]}}' }), function()
      has(run(), "warn", "^No turns found in a transcript with 1 records")
    end)
  end,
  ["no transcript yet is fine"] = function()
    with_env(fake_claude(nil), function()
      local out = run()
      has(out, "ok", "^No transcript yet")
      no(out, "error")
    end)
  end,
  ["no session is information, not a problem"] = function()
    with_env(vim.fn.tempname(), function()
      local out = run()
      has(out, "warn", "config directory .* doesn't exist")
      has(out, "info", "^No agent session found%.")
      no(out, "error")
    end)
  end,
  ["no readers, and a reader whose health check fails"] = function()
    with_env(vim.fn.tempname(), function()
      readers.register("claude", false)
      has(run(), "error", "^No readers registered")
      readers.register("odd", {
        detect = function()
          return {}
        end,
        read = function() end,
        health = function()
          error("kaputt")
        end,
      })
      local out = run()
      has(out, "ok", "^odd %(registered%)")
      has(out, "error", "^odd: health check failed: .*kaputt")
    end)
  end,
}
