---Terminal management for the opencode TUI.
---
---Mirrors claudecode.nvim's terminal module: configuration defaults live here,
---provider selection happens in `get_provider()`, and the rest of the plugin only
---talks to the public API below. With `provider = "auto"` (the default) Snacks is
---tried first — LazyVim ships it — and the native `termopen` provider is used as
---the fallback.
---@module 'opencode.terminal'

local M = {}

---@class OpenCodeTerminalKeys
---@field [string] string|false Buffer-local keymaps set on the managed terminal
---   buffer in both `t` (terminal) and `n` (normal) mode. A value of `false`
---   disables that mapping. Note that a bare `q` in terminal mode is claimed by
---   this table, so TUIs that use `q` themselves need `keys.q = "<C-q>"` or similar.

---@class OpenCodeTerminalConfig
---@field terminal_cmd string Command used to launch the TUI.
---@field split_side "left"|"right" Which side the split opens on.
---@field split_width_percentage number Split width as a fraction of the columns.
---@field auto_insert boolean Enter terminal mode when the TUI gains focus.
---@field auto_close boolean Close the split when the TUI process exits.
---@field git_repo_cwd boolean Resolve the cwd from the git root of the current file.
---@field cwd string|nil Force a working directory (wins over `git_repo_cwd`).
---@field env table<string, string> Extra environment variables for the job.
---@field provider "auto"|"snacks"|"native" Which terminal implementation to use.
---@field provider_opts table Provider-specific options (unused for now; pass-through).
---@field snacks_win_opts table Extra `Snacks.win` config for the snacks provider.
---@field show_native_term_exit_tip boolean Show a one-time hint about escaping the pane.
---@field keys OpenCodeTerminalKeys Escape/hide keymaps for the managed buffer.

---@type OpenCodeTerminalConfig
local defaults = {
	terminal_cmd = "opencode",
	split_side = "right",
	split_width_percentage = 0.25,
	auto_insert = true,
	auto_close = true,
	git_repo_cwd = false,
	cwd = nil,
	env = {},
	provider = "auto",
	provider_opts = {},
	snacks_win_opts = {},
	show_native_term_exit_tip = true,
	keys = {
		["<Esc>"] = "<Esc>",
		-- WARNING: a bare `q` is claimed by this table; TUI keys are then
		-- unreachable. Override it (e.g. `keys = { q = "<C-q>" }`) if the TUI
		-- needs `q`, or set it to `false` to disable.
		-- q = "<cmd>Opencode<cr>",
		["<C-\\><C-N>"] = "<C-\\><C-N>",
		["<C-w>h"] = "<C-w>h",
		["<C-w>j"] = "<C-w>j",
		["<C-w>k"] = "<C-w>k",
		["<C-w>l"] = "<C-w>l",
	},
}

---The effective configuration. Providers read this through `setup()`.
M.defaults = defaults

---Pristine copy of the shipped defaults, so a repeated `setup()` merges user keys
---against the defaults rather than against previously merged ones.
local pristine = vim.deepcopy(defaults)

---Every config key, in a fixed order (`pairs` would skip the nil-valued ones).
local config_keys = {
	"terminal_cmd",
	"split_side",
	"split_width_percentage",
	"auto_insert",
	"auto_close",
	"git_repo_cwd",
	"cwd",
	"env",
	"provider",
	"provider_opts",
	"snacks_win_opts",
	"show_native_term_exit_tip",
	"keys",
}

---Warn once per distinct message; provider fallbacks are checked on every call.
---@type table<string, boolean>
local warned = {}
---@param msg string
local function warn_once(msg)
	if warned[msg] then
		return
	end
	warned[msg] = true
	vim.notify("opencode.nvim: " .. msg, vim.log.levels.WARN)
end

---@type table<string, OpenCodeTerminalProvider>
local providers = {}

---Lazily load a provider module.
---@param name string
---@return OpenCodeTerminalProvider|nil
local function load_provider(name)
	if not providers[name] then
		local ok, provider = pcall(require, "opencode.terminal." .. name)
		if ok and type(provider) == "table" then
			providers[name] = provider
		else
			return nil
		end
	end
	return providers[name]
end

---Resolve the active provider.
---
---`auto` prefers snacks (silently falling back), `snacks` warns when Snacks is
---missing, anything unknown warns. Native is the guaranteed last resort.
---@return OpenCodeTerminalProvider
local function get_provider()
	local configured = defaults.provider

	if configured == "auto" then
		local snacks = load_provider("snacks")
		if snacks and snacks.is_available() then
			return snacks
		end
	elseif configured == "snacks" then
		local snacks = load_provider("snacks")
		if snacks and snacks.is_available() then
			return snacks
		end
		warn_once("`snacks` provider configured but snacks.nvim is not available. Falling back to `native`.")
	elseif configured ~= "native" then
		warn_once("invalid terminal provider " .. tostring(configured) .. ". Falling back to `native`.")
	end

	local native = load_provider("native")
	if not native then
		error("opencode.nvim: critical error - native terminal provider failed to load")
	end
	return native
end

---Working directory for the TUI job.
---@param cfg OpenCodeTerminalConfig
---@return string|nil cwd nil means "inherit Neovim's cwd"
local function resolve_cwd(cfg)
	if type(cfg.cwd) == "string" and cfg.cwd ~= "" then
		return vim.fn.expand(cfg.cwd)
	end

	if cfg.git_repo_cwd then
		local start = vim.fn.fnamemodify(vim.fn.expand("%:p"), ":h")
		if start ~= "" and vim.fs and vim.fs.root then
			local root = vim.fs.root(start, ".git")
			if root then
				return root
			end
		end
	end

	return nil
end

---Build the effective terminal config handed to a provider.
---@param opts_override table|nil Appearance overrides for a single call.
---@return OpenCodeTerminalConfig
local function build_config(opts_override)
	local cfg = vim.deepcopy(defaults)
	if type(opts_override) == "table" then
		local validators = {
			split_side = function(val)
				return val == "left" or val == "right"
			end,
			split_width_percentage = function(val)
				return type(val) == "number" and val > 0 and val < 1
			end,
			cwd = function(val)
				return val == nil or type(val) == "string"
			end,
			git_repo_cwd = function(val)
				return type(val) == "boolean"
			end,
			snacks_win_opts = function(val)
				return type(val) == "table"
			end,
			provider_opts = function(val)
				return type(val) == "table"
			end,
		}
		for key, val in pairs(opts_override) do
			if cfg[key] ~= nil and validators[key] and validators[key](val) then
				cfg[key] = val
			end
		end
	end

	cfg.cwd = resolve_cwd(cfg)
	return cfg
end

---Command string plus environment for the job.
---@param cfg OpenCodeTerminalConfig
---@return string cmd_string
---@return table env_table
local function build_command(cfg)
	local env = {}
	for k, v in pairs(cfg.env or {}) do
		env[k] = tostring(v)
	end
	return cfg.terminal_cmd, env
end

---Apply the terminal configuration.
---@param user_term_config OpenCodeTerminalConfig|nil
function M.setup(user_term_config)
	if type(user_term_config) ~= "table" then
		user_term_config = {}
	end

	-- Start from the shipped defaults so a second setup() call fully replaces the
	-- configuration instead of inheriting the previous one. Mutated in place to
	-- keep the table identity providers already hold a reference to. Iterate over
	-- the key list (not pairs) so nil-valued defaults like `cwd` are cleared too.
	for _, k in ipairs(config_keys) do
		defaults[k] = vim.deepcopy(pristine[k])
	end

	for k, v in pairs(user_term_config) do
		if k == "split_side" then
			if v == "left" or v == "right" then
				defaults.split_side = v
			else
				vim.notify("opencode.nvim: invalid split_side: " .. tostring(v), vim.log.levels.WARN)
			end
		elseif k == "split_width_percentage" then
			if type(v) == "number" and v > 0 and v < 1 then
				defaults.split_width_percentage = v
			else
				vim.notify("opencode.nvim: invalid split_width_percentage: " .. tostring(v), vim.log.levels.WARN)
			end
		elseif k == "provider" then
			if v == "auto" or v == "snacks" or v == "native" then
				defaults.provider = v
			else
				vim.notify("opencode.nvim: invalid provider: " .. tostring(v) .. ". Using 'auto'.", vim.log.levels.WARN)
			end
		elseif k == "auto_close" or k == "auto_insert" or k == "git_repo_cwd" or k == "show_native_term_exit_tip" then
			if type(v) == "boolean" then
				defaults[k] = v
			else
				vim.notify("opencode.nvim: invalid value for " .. k .. ": " .. tostring(v), vim.log.levels.WARN)
			end
		elseif k == "cwd" then
			if v == nil or type(v) == "string" then
				defaults.cwd = v
			else
				vim.notify("opencode.nvim: invalid cwd: " .. tostring(v), vim.log.levels.WARN)
			end
		elseif k == "keys" then
			if type(v) == "table" then
				-- Merge over the (just reset) defaults, so a partial table only
				-- overrides the keys it mentions and `false` disables one.
				defaults.keys = vim.tbl_deep_extend("force", defaults.keys, v)
			else
				vim.notify("opencode.nvim: invalid keys table (expected key -> rhs|false)", vim.log.levels.WARN)
			end
		elseif k == "terminal_cmd" or k == "env" or k == "provider_opts" or k == "snacks_win_opts" then
			if type(v) == "string" or type(v) == "table" then
				defaults[k] = v
			else
				vim.notify("opencode.nvim: invalid value for " .. k .. ": " .. tostring(v), vim.log.levels.WARN)
			end
		end
	end

	get_provider().setup(defaults)
end

---Show and focus the TUI, starting it if needed.
---@param opts_override table|nil
function M.open(opts_override)
	local cfg = build_config(opts_override)
	local cmd_string, env_table = build_command(cfg)
	get_provider().open(cmd_string, env_table, cfg, true)
end

---Hide the TUI pane. The process keeps running.
function M.close()
	get_provider().close()
end

---Toggle visibility regardless of focus.
---@param opts_override table|nil
function M.simple_toggle(opts_override)
	local cfg = build_config(opts_override)
	local cmd_string, env_table = build_command(cfg)
	get_provider().simple_toggle(cmd_string, env_table, cfg)
end

---Focus the TUI when hidden or unfocused; hide it when it already has focus.
---@param opts_override table|nil
function M.focus_toggle(opts_override)
	local cfg = build_config(opts_override)
	local cmd_string, env_table = build_command(cfg)
	get_provider().focus_toggle(cmd_string, env_table, cfg)
end

---Ensure the pane is visible without stealing focus.
---@param opts_override table|nil
---@return boolean success
function M.ensure_visible(opts_override)
	local provider = get_provider()
	if provider.is_visible() then
		return true
	end
	local cfg = build_config(opts_override)
	local cmd_string, env_table = build_command(cfg)
	return provider.open(cmd_string, env_table, cfg, false) and true or false
end

---@return number|nil
function M.get_active_terminal_bufnr()
	return get_provider().get_active_bufnr()
end

---@return number|nil
function M.get_bufnr()
	return M.get_active_terminal_bufnr()
end

---@return boolean
function M.is_visible()
	local provider = get_provider()
	if type(provider.is_visible) == "function" then
		return provider.is_visible()
	end
	return M.get_active_terminal_bufnr() ~= nil
end

---Kill the TUI process and drop the terminal buffer.
function M.stop()
	get_provider().stop()
end

---Send text to the running TUI as if typed at its prompt.
---
---Multi-line text is wrapped in bracketed-paste markers so embedded newlines
---arrive as one literal block instead of several premature submits. A trailing
---carriage return submits unless `opts.submit == false`.
---@param text string
---@param opts { submit?: boolean, focus?: boolean }|nil
---@return boolean success
function M.send_to_terminal(text, opts)
	if type(text) ~= "string" or text == "" then
		vim.notify("opencode.nvim: send_to_terminal: no text provided", vim.log.levels.WARN)
		return false
	end

	opts = opts or {}
	local bufnr = M.get_active_terminal_bufnr()
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		vim.notify("opencode.nvim: cannot send text, no opencode terminal is running.", vim.log.levels.WARN)
		return false
	end

	-- termopen() sets b:terminal_job_id; bo.channel is the fallback that also works
	-- for a terminal recovered by a provider.
	local chan = vim.b[bufnr].terminal_job_id
	if not chan or chan == 0 then
		chan = vim.bo[bufnr].channel
	end
	if not chan or chan == 0 then
		vim.notify("opencode.nvim: cannot send text, buffer has no job channel.", vim.log.levels.WARN)
		return false
	end

	-- Normalize line endings so the only submit byte is the CR appended below.
	local normalized = (text:gsub("\r\n", "\n"):gsub("\r", "\n"))
	local payload = normalized
	if normalized:find("\n", 1, true) then
		payload = "\27[200~" .. normalized .. "\27[201~"
	end
	if opts.submit ~= false then
		payload = payload .. "\r"
	end

	local ok, written = pcall(vim.fn.chansend, chan, payload)
	if not ok or written == 0 then
		vim.notify("opencode.nvim: cannot send text, the terminal channel is closed.", vim.log.levels.WARN)
		return false
	end

	if opts.focus then
		M.open()
	end
	return true
end

return M
