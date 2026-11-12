# eunoe.nvim

## Tests and formatting

- `make test` runs the suite headless (`nvim -n --clean -l tests/run.lua`).
  `EUNOE_TEST=<Lua pattern> make test` runs only the tests whose names match.
  The runner is dependency-free; each `tests/*_spec.lua` returns a table of
  name → function.
- `make fmt` formats with stylua (`lua/ plugin/ tests/`); CI checks the same with
  `stylua --check`, pinned to stylua 2.6.0.
- `tests/docs_spec.lua` requires every config option in `:help` and in the
  README defaults block, a `*eunoe.<name>()*` tag for every function on
  `require("eunoe")`, help lines of at most 78 columns, and resolving
  `|links|`.

## Headless gotchas

- Don't call `:redrawstatus!` on code paths the tests hit: under `nvim -l`
  (seen with Neovim 0.12.6) it intermittently crashes Neovim with SIGBUS
  (exit code 138), even with an empty 'winbar'. The winbar refreshes on its
  own after mode and zoom changes.
- `WinResized` doesn't fire under `nvim -l`. Tests call
  `require("eunoe.view").on_resized(wins)` directly.
