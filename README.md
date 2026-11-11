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
- [Quoting into the prompt](#quoting-into-the-prompt)
- [Commands](#commands)
- [Mappings](#mappings)
- [Configuration](#configuration)
- [Lua API](#lua-api)
- [Agents](#agents)
- [Limitations](#limitations)
- [Why "eunoe"?](#why-eunoe)

## Requirements

- Neovim 0.11 or newer
- Claude Code, with Neovim as its editor (see [Installation](#installation))
- `ps`, to find the agent Neovim was started from (on macOS and Linux it's
  always there)

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
right with the last 10 turns, newest at the bottom, the cursor on the
latest reply:

```markdown
# 6 · You

Can you make the parser skip system reminders?

# 6 · Agent

Yes. Three changes:

1. …
```

Turns are numbered, so "turn 6, point 2" means the same thing to you and
the agent. The buffer is plain read-only Markdown: search it, yank from
it, and use your Markdown plugins.

| Key | Does |
|---|---|
| `]]` / `[[` | Next / previous turn |
| `za`, `zR`, `zM` … | Open and close [truncated text](#long-prompts-and-replies) |
| `>` | Visual mode: [quote](#quoting-into-the-prompt) the selection into the prompt |
| `R` | Reload, e.g. after the agent wrote more |
| `q` | Close |

`:Eunoe all` shows every turn of the session. `:Eunoe` again closes the
split.

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

Lines longer than 80 characters are broken at spaces, so long paragraphs
fold too. Code blocks and tables stay as they are, list items keep their
indent, and quotes keep their `>`. Yanking with `y` copies these line
breaks; quoting doesn't.

Both are [configurable](#configuration): `truncate = false` and
`view = { wrap = false }` turn them off.

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
a linewise one (`V`) whole lines.

Quote short passages. The agent already has the conversation, and every
quoted line is sent again.

## Commands

| Command | Does |
|---|---|
| `:Eunoe` | Open the split with the last turns, or close it |
| `:Eunoe all` | Open the split with every turn |
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
  -- How many turns :Eunoe shows (newest at the bottom); :Eunoe all shows
  -- all of them.
  turns = 10,
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
  },
  -- Keys in the eunoe split (buffer-local). false leaves a key unmapped.
  keys = {
    close = "q",
    next_turn = "]]",
    prev_turn = "[[",
    reload = "R",
    quote = ">", -- Visual mode
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
})
```

`setup()` warns about unknown options and wrong values, and
`:checkhealth eunoe` lists them again.

## Lua API

```lua
local eunoe = require("eunoe")

eunoe.open()              -- open (or refresh) the split
eunoe.open({ all = true })
eunoe.close()
eunoe.toggle()

-- The current session's turns, oldest first, for pickers and other
-- plugins. Each turn: { n = 6, prompt = "…", reply = "…", time = "…" }.
eunoe.turns({ n = 5 }, function(turns, session)
  -- session: { id, pid, reader, transcript, … }
end)
```

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
  -- Optional: label = "My Agent", tested_version = "1.2.3",
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
