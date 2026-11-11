# eunoe.nvim

[![Tests](https://github.com/kaiaberg/eunoe.nvim/actions/workflows/tests.yml/badge.svg)](https://github.com/kaiaberg/eunoe.nvim/actions/workflows/tests.yml)

> But Eunoe behold, that yonder rises;
> Lead him to it, and, as thou art accustomed,
> Revive again the half-dead virtue in him.
>
> — Beatrice, *Purgatorio* XXXIII (trans. Longfellow)

Shows a coding agent's conversation in Neovim: your earlier prompts and
the agent's replies, starting with
[Claude Code](https://claude.com/claude-code). When you press `Ctrl+G` in
Claude Code to write a prompt in Neovim, the conversation disappears
behind the editor, and "about your point 3" means scrolling back after
you're done. `:Eunoe` opens it in a split next to the prompt, so you can
read it, jump between turns and quote from it while you write.

It also works as a side panel next to an agent running in another
terminal or tmux pane.

eunoe only reads the agent's transcript files on your machine. It sends
nothing anywhere and never changes the transcript.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Which session it shows](#which-session-it-shows)
- [Long prompts and replies](#long-prompts-and-replies)
- [Modes: one line per message, everything open](#modes-one-line-per-message-everything-open)
- [Quoting into the prompt](#quoting-into-the-prompt)
- [Commands](#commands)
- [Mappings](#mappings)
- [Configuration](#configuration)
- [Colors](#colors)
- [Lua API](#lua-api)
- [Status line](#status-line)
- [Agents](#agents)
- [Limitations](#limitations)
- [Why "eunoe"?](#why-eunoe)

## Requirements

- Neovim 0.11 or newer
- Claude Code, with Neovim as its editor (see [Installation](#installation))
- `ps`, to find the agent Neovim was started from (on macOS and Linux it's
  always there)
- Optional: a [Nerd Font](https://www.nerdfonts.com) for the icons in the
  headings (or `heading = { icons = false }`)

## Installation

With Neovim's built-in `vim.pack` (0.12+):

```lua
vim.pack.add({ "https://github.com/kaiaberg/eunoe.nvim" })
```

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "kaiaberg/eunoe.nvim", opts = {} }
```

`setup()` is optional; call it only to change the
[defaults](#configuration). eunoe maps no keys by itself. To open it with
a key, map `<Plug>(eunoe-toggle)`, e.g.:

```lua
vim.keymap.set("n", "<leader>e", "<Plug>(eunoe-toggle)")
```

Claude Code opens the editor from `$VISUAL`, then `$EDITOR`, so for
`Ctrl+G`:

```sh
export VISUAL=nvim
```

Run `:checkhealth eunoe` to check the setup. It also shows which session
eunoe finds from where you run it.

## Usage

Press `Ctrl+G` in Claude Code and run `:Eunoe`. A split opens on the
right with every turn of the session, newest at the bottom, the cursor on the
latest reply:

```
╭─ 6 · You ─────────────────────────────────────────── 09:30
│ Can you make the parser skip system reminders?
╰────────────────────────────────────────────────────────────
╭─ 6 · Claude ────────────────────────────────────────────────
│ Yes. Three changes:
│
│ 1. …
╰────────────────────────────────────────────────────────────
```

Turns are numbered, so "turn 6, point 2" means the same thing to you and
the agent. Each message sits in a box in its speaker's
[color](#colors) (gray for you, orange for Claude), each heading has an
icon (left out in these examples), and your prompts show their time. The
box is open on the right, so long code lines don't break it, and it
needs no extra lines: its top is the heading, its bottom the blank line
between messages. `view = { style = "bar" }` shows a bar next to each
message instead. What the headings show is
[configurable](#configuration).

The box, the icons and the time are drawn on top of the text: the
buffer line is just `6 · You`, so `/6 ·` finds turn 6 and yanking copies
no icons. The headings aren't Markdown `#` headings, so Markdown
renderers like
[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)
leave them alone. The rest is plain read-only Markdown: search it, yank
from it, and use your Markdown plugins.

| Key | Does |
|---|---|
| `]]` / `[[` | Next / previous turn |
| `za`, `zo`, `zc` … | Open and close [truncated text](#long-prompts-and-replies) and messages |
| `>` | Visual mode: [quote](#quoting-into-the-prompt) the selection into the prompt |
| `o` | [One line per message](#modes-one-line-per-message-everything-open), and back |
| `O` | Everything open, and back |
| `R` | Reload, e.g. after the agent wrote more |
| `q` | Close |

`:Eunoe` again closes the split.

Before the first prompt of a session there is nothing to show yet; eunoe
says "No conversation yet".

## Which session it shows

- **Started from the agent:** after `Ctrl+G`, Neovim runs as a child of
  Claude Code. eunoe walks up Neovim's parent processes and shows the
  session of the nearest agent among them. This is always the right one,
  however many agents run.
- **Next to the agent:** otherwise it looks for sessions running in
  Neovim's current directory. If there are several, it asks which one and
  remembers the choice.

It follows `/clear` and `/resume`: each `:Eunoe` (and `R`) reads the
session again.

## Long prompts and replies

Prompts and replies longer than 800 characters show their beginning; the
rest sits in a closed fold:

```
… 1,615 more characters (za to expand)
```

The newest reply stays open, since it's usually the one you're answering
(`zc` closes it). Code blocks are never cut in the middle.

Lines longer than 80 characters (or than the window is wide) are broken
at spaces, so long paragraphs fold too. Code blocks and tables stay as they are, list items keep their
indent, and quotes keep their `>`. Yanking with `y` copies these line
breaks; quoting doesn't.

Both are [configurable](#configuration): `truncate = false` and
`view = { wrap = false }` turn them off.

## Modes: one line per message, everything open

Every message is a fold, so the split has three modes, and they're just
fold levels:

| Mode | Shows | Keys |
|---|---|---|
| `oneline` | One line per message | `o`, `zM` |
| `default` | Messages open, long text folded | |
| `expanded` | Everything open | `O`, `zR` |

`o` and `O` switch to their mode, and back to the mode before when it's
on. The cursor stays on its message. `keys.cycle` (unset by default,
e.g. `"<Tab>"`) goes through the modes in this order. `:Eunoe mode
oneline` and `require("eunoe").mode("oneline")` switch by name, and
`view.mode` sets the mode the split opens in. After that, the mode is
kept when you press `R` or open the split again.

One-line mode shows each message's heading and the start of its text.
Use it to skim a long session or find a message, then open it with `o`
or `za`:

```
6 · You     Can you make the parser skip system reminders?
6 · Claude  Yes. Three changes: skip the tags, keep the order, and…
7 · You     Why drop empty turns?
```

Numbers and names are padded to the same width so the messages line up
(`heading.pad`).

Searching with `/` opens the messages that match. Lines are cut at
`view.wrap` (80) characters or the window width. Expanded mode shows
everything, e.g. to read or search a whole session.

## Quoting into the prompt

Select text in the eunoe split and press `>`. eunoe inserts it as a
blockquote in the window you came from (the prompt): on a blank line at
the cursor, or below the cursor line if it has text. The cursor then
waits on the line after the quote, ready for your comment:

```markdown
> Three changes: skip the tags, keep the order, and drop empty turns.

Why drop empty turns?
```

The quote uses the original text, not the folded or wrapped lines on
screen. A characterwise selection (`v`) quotes exactly what you selected,
a linewise one (`V`) whole lines. A selection over closed folds quotes
everything in them, e.g. whole messages in one-line mode.

Quote short passages. The agent already has the conversation, and every
quoted line is sent again.

## Commands

| Command | Does |
|---|---|
| `:Eunoe` | Open the split, or close it |
| `:Eunoe all` | Open the split with every turn, also when `turns` is set |
| `:Eunoe mode [mode]` | Switch to `default`, `oneline` or `expanded`, or show the mode |
| `:checkhealth eunoe` | Check the setup and the current session |

## Mappings

Global mappings exist only as `<Plug>` mappings:

| Mapping | Mode | Does |
|---|---|---|
| `<Plug>(eunoe-toggle)` | Normal | Like `:Eunoe` |
| `<Plug>(eunoe-quote)` | Visual | Quote the selection (in the eunoe split) |

The keys inside the split are set in `keys` (see below); `false` leaves a
key unmapped.

## Configuration

The defaults:

```lua
require("eunoe").setup({
  -- How many turns :Eunoe shows, the newest; nil shows all of them.
  -- :Eunoe all always shows all of them.
  turns = nil,
  view = {
    -- Width of the split: a fraction of the editor's columns (< 1) or a
    -- number of columns.
    width = 0.4,
    -- Move the cursor into the split when it opens.
    focus = true,
    -- Break lines longer than this at spaces (not in code blocks or
    -- tables), so long paragraphs can be truncated too. false keeps
    -- lines as they are.
    wrap = 80,
    -- "box": a box around each message, open on the right. "bar": a bar
    -- next to each message instead.
    style = "box",
    -- The bar's character, in bar style and for messages folded to one
    -- line. false: no bar in bar style.
    bar = "▎",
    -- The mode the split opens in: "default", "oneline" or "expanded".
    mode = "default",
  },
  -- Keys in the eunoe split (buffer-local). false leaves a key unmapped.
  keys = {
    close = "q",
    next_turn = "]]",
    prev_turn = "[[",
    reload = "R",
    quote = ">", -- Visual mode
    oneline = "o", -- one line per message, and back
    expanded = "O", -- everything open, and back
    cycle = false, -- the next mode, e.g. "<Tab>"
  },
  -- Long prompts and replies show their beginning; the rest goes into a
  -- closed fold. false turns truncation off.
  truncate = {
    -- Characters to show before folding the rest. The cut lands at the
    -- end of a line, and never inside a code block.
    chars = 800,
    -- Separate limits for prompts and replies; nil uses chars.
    prompt = nil,
    reply = nil,
    -- Leave the newest reply unfolded.
    open_latest = true,
  },
  -- What the message headings show: "6 · <icon> Claude", the time on
  -- the right.
  heading = {
    -- The turn number.
    number = true,
    -- The · after the number.
    separator = true,
    -- Icons before the names (Nerd Font glyphs). false turns them off,
    -- e.g. without a Nerd Font.
    icons = {
      user = "\u{f007}", -- nf-fa-user
      -- nil: the agent's own icon (Claude Code: nf-cod-claude), or
      -- nf-md-robot for agents without one.
      agent = nil,
    },
    -- The speaker's name: "You", "Claude".
    names = true,
    -- The time of each prompt, at the right end of its heading.
    time = true,
    -- In one-line mode, pad numbers and names to the same width, so the
    -- messages line up.
    pad = true,
  },
})
```

The Claude icon (nf-cod-claude) is only in recent Nerd Fonts releases. If
it shows as a box while the other icons work, update the font, or use
the robot instead: `heading = { icons = { agent = "\u{f06a9}" } }`.

`setup()` warns about unknown options and wrong values, and
`:checkhealth eunoe` lists them again.

## Colors

The split uses these highlight groups. Colorschemes can set them, and so
can you (after `:colorscheme`, which clears all groups). eunoe never
overwrites a group a colorscheme or you set.

| Group | Default |
|---|---|
| `EunoeUser` | Your prompts' headings and boxes: slate gray `#8A93A6`, adjusted |
| `EunoeAgent` | Agents without a color of their own: linked to `Title` |
| `EunoeAgentClaude` | Claude Code's replies: Claude's orange `#D97757`, adjusted |
| `EunoeTime` | The time on the prompt headings: linked to `Comment` |
| `EunoeOneline` | The text in one-line mode: linked to `Normal` |
| `EunoeFolded` | Closed folds in the split (it maps `Folded` to this): linked to `Normal` |
| `EunoeTruncated` | The "… 1,615 more characters" line: linked to `Comment` |

```lua
vim.api.nvim_set_hl(0, "EunoeUser", { fg = "#7aa2f7", bold = true })
```

The speaker colors are adjusted to your background: eunoe keeps the hue
and changes the lightness until the color has 4.5:1 contrast with the
background (the WCAG minimum for text). So Claude's orange is darker on
light themes and still orange. It follows `:colorscheme` and
`'background'`, and each color has a 256-color fallback for terminals
without true color.

## Lua API

```lua
local eunoe = require("eunoe")

eunoe.open()              -- open (or refresh) the split
eunoe.open({ all = true })
eunoe.close()
eunoe.toggle()
eunoe.mode("oneline")     -- switch modes; eunoe.mode() returns the mode

-- The current session's turns, oldest first, for pickers and other
-- plugins. Each turn: { n = 6, prompt = "…", reply = "…", time = "…" }.
eunoe.turns({ n = 5 }, function(turns, session)
  -- session: { id, pid, reader, transcript, … }
end)
```

## Status line

eunoe draws no status line. It exposes data, and you build the
component in lualine, heirline or a plain `'statusline'`:

- `vim.b.eunoe_status`: a table in the eunoe buffer.
- `User EunoeStatus`: fires when the table changes, with the table in
  `ev.data`.
- `require("eunoe").status()`: the same table, computed when called, or
  `nil` when the split isn't open.

```lua
{
  buf = 12,                -- the eunoe buffer
  agent = "Claude Code",   -- the agent's display name
  reader = "claude",
  session = "77044140-…",  -- the session id
  turns = 41,              -- turns shown
  total = 41,              -- turns in the session
  mode = "default",        -- "oneline", "default" or "expanded"
  turn = 38,               -- the turn at the cursor (nil above it)
  role = "reply",          -- "prompt" or "reply"
  speaker = "Claude",      -- "You" or the agent's name
  loaded = 1794400000,     -- when the session was read (os.time())
}
```

The cursor fields follow the cursor: the event fires when the cursor
moves to another message, not on every move.

A lualine component, shown in the eunoe window only:

```lua
local function eunoe()
  local s = vim.b.eunoe_status
  return ("%s · turn %s/%d · %s"):format(s.agent, s.turn or "–", s.total, s.mode)
end
require("lualine").setup({
  sections = {
    lualine_c = {
      { eunoe, cond = function() return vim.b.eunoe_status ~= nil end },
    },
  },
})
```

A plain `'statusline'` for the eunoe window:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "EunoeStatus",
  callback = function(ev)
    local s, win = ev.data, vim.fn.bufwinid(ev.data.buf)
    if win ~= -1 then
      vim.wo[win].statusline = ("%s · turn %s/%d · %s"):format(s.agent, s.turn or "–", s.total, s.mode)
    end
  end,
})
```

In heirline, update the component on the event:
`update = { "User", pattern = "EunoeStatus" }`.

## Agents

| Agent | Support |
|---|---|
| Claude Code | Built in. Last checked with Claude Code 2.1.322 |

Claude Code's transcript format is internal and undocumented, and it
changes between releases. eunoe skips what it doesn't know rather than
failing, so after an update it may show less, not break.
`:checkhealth eunoe` compares the running version with the last checked
one and warns about records it doesn't recognize; please report those.
eunoe respects `$CLAUDE_CONFIG_DIR`.

### Other agents

Support for another agent is a *reader*: one function that finds the
agent's sessions for this Neovim and one that turns a transcript into
turns. Register it from your config or your own plugin, and it gets the
same split, folds, quoting and API:

```lua
require("eunoe").register_reader("myagent", {
  -- Sessions for this Neovim. ctx.chain holds Neovim's ancestor pids
  -- (nearest first), ctx.cwd its working directory.
  -- via = "parent": the session's pid is in ctx.chain.
  -- via = "cwd": the session runs in ctx.cwd.
  detect = function(ctx)
    return { { id = "…", pid = 123, via = "parent", transcript = "/path/to/log" } }
  end,
  -- Parse a transcript (whatever detect put there) into turns, then call
  -- cb(turns), or cb(nil, err). A missing transcript: cb(nil, "ENOENT: …").
  read = function(transcript, cb)
    cb({ { n = 1, prompt = "…", reply = "…" } })
  end,
  -- Optional: label = "My Agent" (for messages), speaker = "Mine" (name
  -- in the reply headings), icon = "…", color = "#rrggbb" (its
  -- EunoeAgentMyagent group), tested_version = "1.2.3",
  -- health = function(health) … end (extra checks for :checkhealth).
})
```

The nearest agent among Neovim's parents wins across all readers.
Registering a reader under the name `claude` replaces the built-in one;
`register_reader("claude", false)` turns it off.

## Limitations

- **No live updates.** In the `Ctrl+G` editor the agent waits for your
  prompt anyway; next to a running agent, press `R`.
- **Prompts and replies only.** Tool calls, their output and thinking
  aren't shown.
- **Subagents and compaction:** subagent conversations are left out.
  After `/compact` eunoe still shows the earlier turns, as the transcript
  keeps them.
- Windows is untested.

## Why "eunoe"?

In Dante's *Purgatorio*, two rivers flow at the top of Mount Purgatory.
Lethe washes away the memory of past sins, and Eunoe, a river Dante made
up (from the Greek for "good mind"), brings back the memory of the good
that was done. Dante drinks from Eunoe in the last canto of
*Purgatorio*, just before he climbs into Paradise. This plugin does a
smaller job: when the agent's screen is hidden behind your editor, it
brings the conversation back. The name is also a nod to its sibling
plugin, [vergil.nvim](https://github.com/kaiaberg/vergil.nvim): Virgil
guides Dante most of the way up the mountain but leaves him shortly
before he reaches Eunoe.

## License

[MIT](LICENSE)
