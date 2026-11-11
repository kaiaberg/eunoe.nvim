local h = require("helpers")
local readers = require("eunoe.readers")
local eunoe = require("eunoe")
local view = require("eunoe.view")

local function reset_view()
  vim.cmd("silent! only")
  vim.cmd("enew!")
  for buf in pairs(view.state) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  view.state = {}
end

--- Run `fn` with a fresh registry and `vim.notify` captured; restore after.
local function isolated(fn)
  readers._reset()
  local notify, notes = vim.notify, {}
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(fn, notes)
  vim.notify = notify
  readers._reset()
  reset_view()
  if not ok then
    error(err, 0)
  end
end

local function parent_pid()
  return vim.uv.os_getppid()
end

local function noop_read(_, cb)
  cb({})
end

return {
  ["register: validates name and reader"] = function()
    isolated(function()
      local function fails(pattern, ...)
        local args = { ... }
        local ok, err = pcall(function()
          eunoe.register_reader(unpack(args))
        end)
        h.eq(ok, false)
        h.truthy(tostring(err):find(pattern), tostring(err))
      end
      fails("reader name must be", "bad name", { detect = noop_read, read = noop_read })
      fails("must be a table", "x", "not a table")
      fails("needs a read function", "x", { detect = function() end })
      fails("needs a detect function", "x", { read = noop_read })
    end)
  end,
  ["all: Claude Code built in, others appended in order"] = function()
    isolated(function()
      local r = { detect = function() end, read = noop_read }
      eunoe.register_reader("b", r)
      eunoe.register_reader("a", r)
      local all, order = readers.all()
      h.eq(order, { "b", "a", "claude" })
      h.eq(all.claude, require("eunoe.readers.claude"))
    end)
  end,
  ["register: replaces the built-in, false removes a reader"] = function()
    isolated(function()
      local mine = { detect = function() end, read = noop_read }
      eunoe.register_reader("claude", mine)
      h.eq(readers.get("claude"), mine, "registered before first use")
      eunoe.register_reader("claude", false)
      h.eq(readers.get("claude"), nil)
      local _, order = readers.all()
      h.eq(order, {})
    end)
    isolated(function()
      readers.all() -- built-ins loaded
      local mine = { detect = function() end, read = noop_read }
      eunoe.register_reader("claude", mine)
      h.eq(readers.get("claude"), mine, "registered after first use")
    end)
  end,
  [":Eunoe with an external reader"] = function()
    isolated(function()
      eunoe.register_reader("claude", false)
      eunoe.register_reader("fake", {
        detect = function(ctx)
          return { { id = "s1", pid = parent_pid(), via = "parent", transcript = "token-" .. ctx.cwd } }
        end,
        read = function(transcript, cb)
          h.truthy(transcript:find("^token%-"), "read gets what detect returned")
          vim.schedule(function()
            cb({ { n = 1, prompt = "Hello fake", reply = "Hi from fake" } })
          end)
        end,
      })
      eunoe.open()
      h.wait(function()
        return view.current() ~= nil
      end)
      local _, buf = view.current()
      h.eq(vim.api.nvim_buf_get_name(buf), "eunoe://fake/s1")
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      h.truthy(text:find("Hi from fake", 1, true), text)
    end)
  end,
  ["the nearest ancestor wins across readers; a wrong parent pid counts as cwd"] = function()
    isolated(function()
      local session = require("eunoe.session")
      local ctx = { pid = 10, chain = { 20, 30 }, cwd = "/w" }
      local function reader(sessions)
        return {
          detect = function()
            return sessions
          end,
          read = noop_read,
        }
      end
      eunoe.register_reader("claude", false)
      eunoe.register_reader("far", reader({ { id = "far", pid = 30, via = "parent" } }))
      eunoe.register_reader("near", reader({ { id = "near", pid = 20, via = "parent" } }))
      local found = session.find(ctx)
      h.eq(found[1].id, "near")
      h.eq(found[1].reader, "near")
      eunoe.register_reader("near", reader({ { id = "liar", pid = 99, via = "parent", updated = 1 } }))
      eunoe.register_reader("far", false)
      found = session.find(ctx)
      h.eq(#found, 1)
      h.eq(found[1].via, "cwd")
    end)
  end,
  ["malformed sessions are skipped"] = function()
    isolated(function(notes)
      eunoe.register_reader("claude", false)
      eunoe.register_reader("bad", {
        detect = function()
          return { "nope", { id = 1, pid = parent_pid(), via = "parent" }, { id = "x", pid = parent_pid(), via = "?" } }
        end,
        read = noop_read,
      })
      eunoe.open()
      h.wait(function()
        return #notes > 0
      end)
      h.truthy(notes[1].msg:find("no agent session found"), notes[1].msg)
    end)
  end,
  ["a reader that fails reports an error instead of crashing"] = function()
    for _, case in ipairs({
      {
        read = function()
          error("boom")
        end,
        expect = 'reader "flaky" failed: .*boom',
      },
      {
        read = function(_, cb)
          cb(nil, "disk on fire")
        end,
        expect = "can't read t: disk on fire",
      },
    }) do
      isolated(function(notes)
        eunoe.register_reader("claude", false)
        eunoe.register_reader("flaky", {
          detect = function()
            return { { id = "s", pid = parent_pid(), via = "parent", transcript = "t" } }
          end,
          read = case.read,
        })
        eunoe.open()
        h.wait(function()
          return #notes > 0
        end)
        h.eq(notes[1].level, vim.log.levels.ERROR)
        h.truthy(notes[1].msg:find(case.expect), notes[1].msg)
        h.eq(view.current(), nil)
      end)
    end
  end,
}
