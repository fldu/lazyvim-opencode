---Minimal OpenCode TUI integration for Neovim.
---
---Public entry point: config + user commands + keymaps, delegating all terminal
---work to `opencode.terminal` (which picks the Snacks or native provider).
---@module 'opencode'

local M = {}

local terminal = require("opencode.terminal")

---@class OpenCodeConfig
---@field terminal_cmd string Command used to launch the TUI. Alias for `terminal.terminal_cmd`.
---@field split_side "left"|"right" Which side the split opens on. Alias for `terminal.split_side`.
---@field split_width_percentage number Split width as a fraction of the columns. Alias for `terminal.split_width_percentage`.
---@field auto_insert boolean Enter terminal mode when the TUI gains focus. Alias for `terminal.auto_insert`.
---@field auto_close boolean Close the split when the TUI process exits. Alias for `terminal.auto_close`.
---@field git_repo_cwd boolean Resolve the cwd from the git root of the current file. Alias for `terminal.git_repo_cwd`.
---@field cwd string|nil Force a working directory (wins over `git_repo_cwd`). Alias for `terminal.cwd`.
---@field keys string[] Normal-mode keymaps registered by `setup()`. Set to `{}` to disable.
---   NOTE: this is the plugin's *toggle* keymaps. Escape keymaps for the terminal
---   buffer live in `terminal.keys`.
---@field terminal table Terminal options (provider, snacks_win_opts, escape keys, ...).

---Top-level keys that are forwarded verbatim into the `terminal` table. They stay
---supported as aliases so existing configs keep working.
local forwarded_keys = {
	"terminal_cmd",
	"split_side",
	"split_width_percentage",
	"auto_insert",
	"auto_close",
	"git_repo_cwd",
	"cwd",
}

---Show and focus the TUI, starting it if needed.
function M.open(opts_override)
	terminal.open(opts_override)
end

---Hide the TUI pane. The process keeps running; use `stop` to kill it.
function M.close()
	terminal.close()
end

---Kill the TUI process and drop the terminal buffer.
function M.stop()
	terminal.stop()
end

---Focus the TUI if hidden or unfocused, otherwise hide it.
function M.toggle(opts_override)
	terminal.focus_toggle(opts_override)
end

---@return boolean
function M.is_visible()
	return terminal.is_visible()
end

---@return number|nil
function M.get_bufnr()
	return terminal.get_active_terminal_bufnr()
end

---Send text to the running TUI as if typed at its prompt.
---@param text string
---@param opts { submit?: boolean, focus?: boolean }|nil
---@return boolean success
function M.send_to_terminal(text, opts)
	return terminal.send_to_terminal(text, opts)
end

local function create_commands()
	vim.api.nvim_create_user_command("Opencode", M.toggle, { desc = "Toggle the opencode TUI" })
	vim.api.nvim_create_user_command("OpencodeFocus", M.open, { desc = "Show/focus the opencode TUI" })
	vim.api.nvim_create_user_command("OpencodeStop", M.stop, { desc = "Stop the opencode TUI" })
end

---Build the terminal config from a user config, mapping top-level aliases.
---@param opts OpenCodeConfig
---@return table terminal_opts
local function build_terminal_opts(opts)
	local term_opts = type(opts.terminal) == "table" and vim.deepcopy(opts.terminal) or {}
	for _, key in ipairs(forwarded_keys) do
		if opts[key] ~= nil and term_opts[key] == nil then
			term_opts[key] = opts[key]
		end
	end
	return term_opts
end

---Toggle keymaps registered by the last `setup()` call, so a later call can
---replace them instead of stacking duplicates.
---@type string[]
local registered_keys = {}

---@param opts OpenCodeConfig|nil
---@return OpenCodeConfig
function M.setup(opts)
	opts = type(opts) == "table" and opts or {}

	terminal.setup(build_terminal_opts(opts))

	local keys = opts.keys
	if keys == nil then
		keys = { "<leader>ac" }
	end
	create_commands()

	for _, lhs in ipairs(registered_keys) do
		pcall(vim.keymap.del, "n", lhs)
	end
	registered_keys = {}
	for _, lhs in ipairs(keys or {}) do
		vim.keymap.set("n", lhs, "<cmd>Opencode<cr>", { desc = "Toggle opencode", silent = true })
		registered_keys[#registered_keys + 1] = lhs
	end

	local resolved = build_terminal_opts(opts)
	resolved.keys = keys
	return resolved
end

return M
