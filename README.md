# opencode.nvim

Minimal Neovim integration for the [opencode](https://opencode.ai) TUI — one split, one toggle.

Pure Lua, zero dependencies. It just launches `opencode` in a side split and toggles it.

## Requirements

- Neovim >= 0.8.0
- The `opencode` CLI in `$PATH` — <https://opencode.ai>

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "fldu/lazyvim-opencode",
  config = true,
  cmd = { "Opencode", "OpencodeFocus", "OpencodeStop" },
  keys = {
    { "<leader>ac", "<cmd>Opencode<cr>", desc = "Toggle opencode" },
  },
  opts = {}, -- defaults: terminal_cmd = "opencode", split_side = "right", ...
}
```

Note: `setup()` also registers `<leader>ac` by default via `opts.keys`, so the `keys` entry above
is optional — pick one, not both.

## Usage

| Command           | What it does                                       |
| ----------------- | -------------------------------------------------- |
| `:Opencode`       | Toggle: focus the TUI, or hide the split if focused |
| `:OpencodeFocus`  | Always show and focus the TUI (starts it if needed) |
| `:OpencodeStop`   | Kill the TUI process and drop the terminal buffer   |

## Configuration

All options are optional; these are the defaults:

```lua
{
  terminal_cmd = "opencode",       -- Command used to launch the TUI.
  split_side = "right",            -- Which side the split opens on ("left" or "right").
  split_width_percentage = 0.4,    -- Split width as a fraction of the columns.
  auto_insert = true,              -- Enter terminal mode when the TUI gains focus.
  auto_close = true,               -- Close the split when the TUI process exits.
  git_repo_cwd = false,            -- Resolve the cwd from the git root of the current file.
  cwd = nil,                       -- Force a working directory (wins over `git_repo_cwd`).
  keys = { "<leader>ac" },         -- Normal-mode keymaps. Set to `{}` to disable.
}
```

`setup()` returns the resolved config, so you can read it back from your plugin spec.

## How it works

- `setup()` creates the three user commands and registers the normal-mode keymaps.
- The TUI runs via `vim.fn.termopen` in a vertical split, sized as a fraction of your columns
  (minimum 20 columns).
- Hiding the split (`:Opencode` while focused) keeps the TUI process running; focusing it again
  re-opens a split for the same buffer, so session state survives.
- The split closes automatically when the TUI process exits. Set `auto_close = false` to keep the
  split around and scroll back through the output after exit.
- `:OpencodeStop` stops the job and deletes the buffer, so the next toggle starts fresh.
