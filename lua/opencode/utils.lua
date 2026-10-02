---Shared helpers for the opencode terminal providers.
---
---Ported (and trimmed) from claudecode.nvim so the native and snacks providers
---behave identically where they need to.
---@module 'opencode.utils'

local M = {}

---Track whether the one-time "how to leave this pane" hint was already shown.
---@type boolean
local tip_shown = false

---Normalize an optional focus flag; `nil` means "focus", like claudecode.
---@param focus boolean|nil
---@return boolean
function M.normalize_focus(focus)
	if focus == nil then
		return true
	end
	return focus
end

---Split a command string into an argument vector using POSIX shell word rules.
---
---Honors single quotes, double quotes, and backslash escapes so a provider can
---spawn the TUI directly (no shell) while preserving quoted arguments. Avoiding
---the shell also keeps bracketed arguments (e.g. `opencode --model=x[1m]`) from
---being glob-expanded by zsh/bash.
---@param cmd string
---@return string[] argv
function M.shell_split(cmd)
	local argv = {}
	local current = nil -- nil = between words; string (incl. "") = building a word
	local i = 1
	local n = #cmd
	while i <= n do
		local c = cmd:sub(i, i)
		if c == " " or c == "\t" then
			if current ~= nil then
				argv[#argv + 1] = current
				current = nil
			end
		elseif c == "'" then
			-- Single quotes: everything up to the next single quote is literal.
			current = current or ""
			local close = cmd:find("'", i + 1, true)
			if close then
				current = current .. cmd:sub(i + 1, close - 1)
				i = close
			else
				current = current .. cmd:sub(i + 1)
				i = n
			end
		elseif c == '"' then
			-- Double quotes: backslash escapes only " \ $ `.
			current = current or ""
			i = i + 1
			while i <= n do
				local d = cmd:sub(i, i)
				if d == '"' then
					break
				elseif d == "\\" and i < n then
					local nextc = cmd:sub(i + 1, i + 1)
					if nextc == '"' or nextc == "\\" or nextc == "$" or nextc == "`" then
						current = current .. nextc
						i = i + 1
					else
						current = current .. d
					end
				else
					current = current .. d
				end
				i = i + 1
			end
		elseif c == "\\" and i < n then
			current = (current or "") .. cmd:sub(i + 1, i + 1)
			i = i + 1
		else
			current = (current or "") .. c
		end
		i = i + 1
	end
	if current ~= nil then
		argv[#argv + 1] = current
	end
	return argv
end

---Expand a leading `~` or `~/` in a single argument, like a shell would.
---@param arg string
---@return string
function M.expand_tilde(arg)
	if arg:sub(1, 1) ~= "~" then
		return arg
	end
	local home = os.getenv("HOME")
	if not home or home == "" then
		return arg
	end
	if arg == "~" then
		return home
	elseif arg:sub(1, 2) == "~/" then
		return home .. arg:sub(2)
	end
	return arg
end

---Parse a command string into an argv list: shell-style splitting plus tilde
---expansion. Globbing and variable expansion are deliberately NOT performed.
---@param cmd string
---@return string[] argv
function M.parse_command(cmd)
	local argv = M.shell_split(cmd)
	for i = 1, #argv do
		argv[i] = M.expand_tilde(argv[i])
	end
	return argv
end

---Descriptions for the default buffer-local escape keymaps.
---@type table<string, string>
local key_descriptions = {
	["<Esc>"] = "opencode: leave terminal insert mode",
	["q"] = "opencode: hide the pane (the TUI keeps running)",
	["<C-\\><C-N>"] = "opencode: return to Normal mode",
	["<C-w>h"] = "opencode: focus the window to the left",
	["<C-w>j"] = "opencode: focus the window below",
	["<C-w>k"] = "opencode: focus the window above",
	["<C-w>l"] = "opencode: focus the window to the right",
}

---Make a freshly spawned terminal buffer behave: unlisted, self-hiding, and
---carrying the buffer-local escape keymaps so the user can never get trapped.
---
---`termopen` auto-names the buffer `term://{cwd}//{pid}:{cmd}`, which shows up in
---the bufferline as `$PID:opencode`. We overwrite it with a stable friendly name
---and drop it out of the buffer list entirely.
---@param bufnr number
---@param config OpenCodeTerminalConfig
function M.adopt_terminal_buffer(bufnr, config)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].buflisted = false
	-- pcall: a duplicate name (two terminals, same cwd) must not break the open.
	pcall(vim.api.nvim_buf_set_name, bufnr, "opencode")

	M.setup_terminal_keymaps(bufnr, config)
end

---Register the buffer-local terminal-mode (`t`) and normal-mode (`n`) keymaps
---that let the user leave the pane. A key mapped to `false` is skipped, so
---individual defaults can be disabled without dropping the rest.
---
---These are buffer-local, so Neovim removes them automatically when the managed
---buffer is wiped — no manual cleanup needed.
---@param bufnr number
---@param config OpenCodeTerminalConfig
function M.setup_terminal_keymaps(bufnr, config)
	local maps = (config and config.keys) or {}
	for lhs, rhs in pairs(maps) do
		if type(lhs) == "string" and lhs ~= "" and rhs ~= false then
			local desc = key_descriptions[lhs] or ("opencode: " .. lhs)
			for _, mode in ipairs({ "t", "n" }) do
				vim.keymap.set(mode, lhs, rhs, {
					buffer = bufnr,
					silent = true,
					desc = desc,
				})
			end
		end
	end
end

---Show the one-time hint telling the user how to get back to the editor.
---@param config OpenCodeTerminalConfig
function M.show_exit_tip(config)
	if not config or config.show_native_term_exit_tip == false then
		return
	end
	if tip_shown then
		return
	end
	tip_shown = true
	vim.notify(
		"opencode.nvim: <Esc> leaves terminal insert mode, q hides the pane (the TUI keeps running), "
			.. "Ctrl-\\ Ctrl-N also returns to Normal mode.",
		vim.log.levels.INFO
	)
end

---Reset the one-time hint. Exposed for tests.
function M._reset_exit_tip()
	tip_shown = false
end

return M
