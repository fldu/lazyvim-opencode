# opencode.nvim

Minimal Neovim integration for the [opencode](https://opencode.ai) TUI — one split, one toggle.

Pure Lua, no hard dependencies. It launches `opencode` in a side split, gives you a
pane you can always escape from, and remembers the process when you hide it.

## Requirements

- Neovim >= 0.8.0
- The `opencode` CLI in `$PATH` — <https://opencode.ai>
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim). When present it is used for the
  terminal; otherwise the plugin uses a native `termopen` split. LazyVim ships Snacks, so this
  usually just works.

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

| Command          | What it does                                       |
| ---------------- | -------------------------------------------------- |
| `:Opencode`      | Toggle: focus the TUI, or hide the split if focused |
| `:OpencodeFocus` | Always show and focus the TUI (starts it if needed) |
| `:OpencodeStop`  | Kill the TUI process and drop the terminal buffer   |

## Getting out of the pane

The terminal buffer gets buffer-local keymaps, so you can always leave:

| Key            | Mode      | What it does                                          |
| -------------- | --------- | ----------------------------------------------------- |
| `<Esc>`        | `t`, `n`  | Leave terminal insert mode (stays in the pane)        |
| `q`            | `t`, `n`  | Hide the pane — the TUI keeps running                 |
| `<C-\><C-N>`   | `t`, `n`  | Canonical Neovim "back to Normal mode"                 |
| `<C-w>h/j/k/l` | `t`, `n`  | Move to another window without fighting the TUI       |

The first time the pane opens you also get a one-time notification reminding you of these.

> **`q` caveat:** a bare `q` is claimed by this table, so a TUI that uses `q` for something will no
> longer receive it. Move it if you need that key — e.g. `terminal = { keys = { ["<C-q>"] =
> "<cmd>Opencode<cr>", q = false } }` — or disable it with `q = false`.

Hiding the pane never kills the process. Only `:OpencodeStop` does.

## Configuration

All options are optional; these are the defaults:

```lua
{
  -- Top-level aliases, kept for backwards compatibility. Each one is forwarded
  -- into the `terminal` table below unless you set it there explicitly.
  terminal_cmd = "opencode",    -- Command used to launch the TUI.
  split_side = "right",         -- Which side the split opens on ("left" or "right").
  split_width_percentage = 0.2, -- Split width as a fraction of the columns.
  auto_insert = true,           -- Enter terminal mode when the TUI gains focus.
  auto_close = true,            -- Close the split when the TUI process exits.
  git_repo_cwd = false,         -- Resolve the cwd from the git root of the current file.
  cwd = nil,                    -- Force a working directory (wins over `git_repo_cwd`).
  keys = { "<leader>ac" },      -- Normal-mode keymaps. Set to `{}` to disable.

  terminal = {
    -- Repeat any of the aliases above here; these win over the top level.
    terminal_cmd = "opencode",
    split_side = "right",
    split_width_percentage = 0.2,
    auto_insert = true,
    auto_close = true,
    git_repo_cwd = false,
    cwd = nil,

    provider = "auto",       -- "auto" (try snacks, else native) | "snacks" | "native"
    provider_opts = {},      -- Reserved for provider-specific options.
    snacks_win_opts = {},    -- Extra Snacks.win config, e.g. { position = "float" }.
    env = {},                -- Extra environment variables for the TUI process.

    -- One-time "here is how to get back to your editor" notification.
    show_native_term_exit_tip = true,

    -- Buffer-local escape keymaps on the managed terminal buffer. Any of these
    -- can be remapped; `false` disables one. See "Getting out of the pane".
    keys = {
      ["<Esc>"] = "<Esc>",
      q = "<cmd>Opencode<cr>",
      ["<C-\\><C-N>"] = "<C-\\><C-N>",
      ["<C-w>h"] = "<C-w>h",
      ["<C-w>j"] = "<C-w>j",
      ["<C-w>k"] = "<C-w>k",
      ["<C-w>l"] = "<C-w>l",
    },
  },
}
```

`setup()` returns the resolved config, so you can read it back from your plugin spec.

### Providers

| `provider` | Behaviour                                                                  |
| ---------- | -------------------------------------------------------------------------- |
| `"auto"`   | Try Snacks first; silently use native when Snacks is not loadable. Default.  |
| `"snacks"` | Use Snacks; warn and fall back to native when it is unavailable.            |
| `"native"` | Always the built-in `termopen` split.                                        |

Snacks is checked with `pcall(require, "snacks")` at open time, so the plugin has no hard
dependency on it. If `Snacks.terminal.open()` errors or hands back an unusable handle, the open
falls back to the native provider (and every later `close`/`stop`/toggle keeps going through it).

## Buffer names

`termopen()` would normally leave the buffer named `term://{cwd}//{pid}:{cmd}`, which shows up in
the bufferline as `$PID:opencode`. This plugin renames the managed buffer to `opencode` and sets:

- `buflisted = false` — it never appears in `:ls`, the bufferline, or buffer switcher pickers
- `bufhidden = "hide"` — hiding the pane keeps the buffer (and the running process)

The same treatment is re-applied when a hidden terminal is shown again, and to a terminal recovered
after this module reloads.

## How it works

- `setup()` creates the three user commands and registers the normal-mode toggle keymaps.
- `lua/opencode/terminal.lua` owns the config, resolves the cwd, picks a provider, and exposes the
  API: `setup`, `open`, `close`, `simple_toggle`, `focus_toggle`, `ensure_visible`,
  `get_active_terminal_bufnr`, `send_to_terminal`, `is_visible`, `get_bufnr`, `stop`.
- `lua/opencode/terminal/native.lua` runs `opencode` via `termopen` in a full-height vertical
  split, sized as a fraction of your columns (minimum 20).
- `lua/opencode/terminal/snacks.lua` does the same through `Snacks.terminal` with `interactive = true`.
- `lua/opencode/utils.lua` holds the shared bits: command parsing, buffer hygiene, escape keymaps,
  and the exit hint.
- Hiding the split keeps the TUI process running; showing it again reuses the same buffer, so
  session state survives.
- The split closes automatically when the TUI process exits. Set `auto_close = false` to keep the
  split around and scroll back through the output after exit.

### Lua API

```lua
require("opencode").setup(opts)
require("opencode").open()      -- show + focus (starts if needed)
require("opencode").close()     -- hide, keep running
require("opencode").stop()      -- kill + delete
require("opencode").toggle()    -- focus if hidden/unfocused, hide if focused
require("opencode").is_visible()
require("opencode").get_bufnr()

-- Send text as if typed at the TUI prompt. Multi-line text is wrapped in
-- bracketed-paste markers so newlines do not submit early; a trailing "\r"
-- submits unless `submit = false`.
require("opencode").send_to_terminal("hello")
require("opencode").send_to_terminal("line 1\nline 2", { submit = false, focus = true })
```