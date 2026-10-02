---Snacks.nvim terminal provider for the opencode TUI.
---
---Optional: only used when `snacks.nvim` is installed and loadable. Every call
---into Snacks is `pcall`-guarded and any failure falls back to the native
---provider so the plugin never hard-depends on Snacks.
---@module 'opencode.terminal.snacks'

local M = {}

local utils = require("opencode.utils")

---@type OpenCodeTerminalConfig
local config = require("opencode.terminal").defaults

---@type table|nil The live `Snacks.terminal` instance, if any.
local terminal = nil

---Set once we hand a terminal over to the native provider. After that every call
---is forwarded, so a later `close`/`stop`/`toggle` still reaches the terminal the
---user can actually see instead of silently doing nothing here.
---@type boolean
local delegated = false

---@return boolean
local function is_available()
	local ok, snacks = pcall(require, "snacks")
	if not ok or type(snacks) ~= "table" then
		return false
	end
	return snacks.terminal ~= nil and snacks.terminal.open ~= nil
end

---Resolve the Snacks module, or nil when unavailable.
---@return table|nil
local function snacks_module()
	local ok, snacks = pcall(require, "snacks")
	if ok and type(snacks) == "table" and snacks.terminal then
		return snacks
	end
	return nil
end

---Window config, or nil when unavailable/hidden.
---@param win number|nil
---@return table|nil
local function win_get_config(win)
	if not (win and vim.api.nvim_win_is_valid(win)) then
		return nil
	end
	local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
	return ok and cfg or nil
end

---A real split reports `relative == ""`; a float reports "editor"/"win"/"cursor".
---@param win number|nil
---@return boolean
local function win_is_floating(win)
	local cfg = win_get_config(win)
	return cfg ~= nil and cfg.relative ~= nil and cfg.relative ~= ""
end

---@param win number|nil
---@return boolean
local function win_is_config_hidden(win)
	local cfg = win_get_config(win)
	return cfg ~= nil and cfg.hide == true
end

---@return boolean
local function supports_config_hide()
	return vim.fn.has("nvim-0.10") == 1
end

---Is the Snacks terminal live?
---@param term table|nil
---@return boolean
local function buf_valid(term)
	return term ~= nil
		and type(term.buf_valid) == "function"
		and term:buf_valid()
		and term.buf ~= nil
		and vim.api.nvim_buf_is_valid(term.buf)
end

---Visible == a live, non-config-hidden window actually showing our buffer.
---@param term table|nil
---@return boolean
local function is_visible(term)
	local win = term and term.win
	if not (win and vim.api.nvim_win_is_valid(win)) then
		return false
	end
	if win_is_config_hidden(win) then
		return false
	end
	return vim.api.nvim_win_get_buf(win) == term.buf
end

---@param term table
local function maybe_start_insert(term, cfg)
	if not cfg or cfg.auto_insert ~= false then
		if
			term.buf
			and vim.api.nvim_buf_is_valid(term.buf)
			and vim.bo[term.buf].buftype == "terminal"
			and term.win
			and vim.api.nvim_win_is_valid(term.win)
		then
			pcall(vim.api.nvim_win_call, term.win, function()
				vim.cmd("startinsert")
			end)
		end
	end
end

---@param term table
---@param win number
local function focus_win(term, win, cfg)
	win = win or term.win
	if not (win and vim.api.nvim_win_is_valid(win)) then
		return
	end
	vim.api.nvim_set_current_win(win)
	maybe_start_insert(term, cfg)
end

---@param term table
---@param cfg OpenCodeTerminalConfig
local function maybe_focus(term, cfg)
	if is_visible(term) then
		focus_win(term, nil, cfg)
	end
end

---Hide the terminal window, keeping the buffer and the running job alive.
---
---Closes the split window (a Snacks float is config-hidden when possible), which
---is the same "don't destroy+recreate" trick the native provider uses: recreating
---the window drifts a TUI's cursor anchor by one row per toggle.
---@param term table
local function hide(term)
	if not is_visible(term) then
		return
	end
	local win = term.win
	if win_is_floating(win) and supports_config_hide() then
		pcall(vim.api.nvim_win_set_config, win, { hide = true })
		-- Neovim does not auto-leave a config-hidden window; step out of it.
		if vim.api.nvim_get_current_win() == win then
			pcall(vim.cmd, "wincmd p")
		end
	elseif pcall(vim.api.nvim_win_close, win, false) then
		term.win = nil
		term.closed = false
	end
end

---Resolve a Snacks width/height to cells: a fraction in (0,1) scales `total`, a
---value >= 1 is absolute, otherwise fall back to `default_frac` of `total`.
---@param val any
---@param total number
---@param default_frac number
---@return number
local function resolve_size(val, total, default_frac)
	if type(val) == "number" and val > 0 then
		if val < 1 then
			return math.max(1, math.floor(total * val))
		end
		return math.floor(val)
	end
	return math.max(1, math.floor(total * default_frac))
end

---Show the terminal window, recreating side/top/bottom splits natively.
---@param term table
---@param cfg OpenCodeTerminalConfig
---@param focus_term boolean|nil
---@return boolean success
local function show(term, cfg, focus_term)
	focus_term = utils.normalize_focus(focus_term)
	if not buf_valid(term) then
		return false
	end

	local win = term.win
	if win and vim.api.nvim_win_is_valid(win) and win_is_config_hidden(win) then
		pcall(vim.api.nvim_win_set_config, win, { hide = false })
		if focus_term then
			focus_win(term, win, cfg)
		end
		return true
	end

	if is_visible(term) then
		if focus_term then
			focus_win(term, nil, cfg)
		end
		return true
	end

	-- Window is gone: recreate it. Side splits are recreated natively (drift-free);
	-- anything else (floats) is handed back to Snacks so it owns its own geometry.
	local win_opts = (cfg and cfg.snacks_win_opts) or {}
	local position = win_opts.position or (cfg and cfg.split_side) or "right"
	local snacks = snacks_module()

	if not (position == "left" or position == "right" or position == "top" or position == "bottom") then
		if snacks and type(term.show) == "function" and pcall(term.show, term) then
			if focus_term then
				maybe_focus(term, cfg)
			end
			return true
		end
		return false
	end

	local original_win = vim.api.nvim_get_current_win()
	local horizontal = position == "top" or position == "bottom"
	local lead = (position == "top" or position == "left") and "topleft " or "botright "
	local size = horizontal and resolve_size(win_opts.height, vim.o.lines, 0.5)
		or resolve_size(win_opts.width, vim.o.columns, cfg.split_width_percentage or 0.3)

	vim.cmd(lead .. size .. (horizontal and "split" or "vsplit"))
	local new_win = vim.api.nvim_get_current_win()
	if not horizontal then
		pcall(vim.api.nvim_win_set_height, new_win, vim.o.lines)
	end
	-- Set term.win before nvim_win_set_buf so Snacks' own autocmds (if any survive)
	-- see a valid window and do not tear the instance down.
	term.win = new_win
	term.closed = false
	vim.api.nvim_win_set_buf(new_win, term.buf)
	-- Re-assert hygiene/escape keymaps: buffer-local maps survive a window
	-- recreate, but a terminal adopted from another session would not have them.
	utils.adopt_terminal_buffer(term.buf, config)
	-- Window-local Snacks state (winhighlight, win vars) is lost with the window.
	if snacks and snacks.util and snacks.util.wo and term.opts and term.opts.wo then
		pcall(snacks.util.wo, new_win, term.opts.wo)
	end

	if focus_term then
		maybe_focus(term, cfg)
	elseif vim.api.nvim_win_is_valid(original_win) then
		vim.api.nvim_set_current_win(original_win)
	end
	return true
end

---Build the Snacks terminal options for this open.
---@param cfg OpenCodeTerminalConfig
---@param env_table table
---@param focus_term boolean
---@return table opts
local function build_opts(cfg, env_table, focus_term)
	local should_insert = focus_term and cfg.auto_insert ~= false
	local opts = {
		cwd = cfg.cwd,
		start_insert = should_insert,
		auto_insert = should_insert,
		auto_close = false,
		-- The TUI owns the tty: no "press <CR> to enter" prompt on focus.
		interactive = true,
		win = vim.tbl_deep_extend("force", {
			position = cfg.split_side,
			width = math.max(20, math.floor(vim.o.columns * cfg.split_width_percentage)),
			height = vim.o.lines,
			relative = "editor",
		}, cfg.snacks_win_opts or {}),
	}
	if env_table and next(env_table) ~= nil then
		opts.env = env_table
	end
	return opts
end

---Register exit/wipe hooks on a fresh Snacks terminal instance.
---@param term table
---@param cfg OpenCodeTerminalConfig
local function setup_events(term, cfg)
	if cfg.auto_close then
		pcall(function()
			term:on("TermClose", function()
				if terminal == term then
					terminal = nil
				end
				vim.schedule(function()
					pcall(term.close, term, { buf = true })
				end)
			end, { buf = true })
		end)
	end
	pcall(function()
		term:on("BufWipeout", function()
			if terminal == term then
				terminal = nil
			end
		end, { buf = true })
	end)
end

---Forward everything to the native provider from now on.
---@return OpenCodeTerminalProvider
local function native()
	delegated = true
	local mod = require("opencode.terminal.native")
	mod.setup(config)
	return mod
end

---@param cfg OpenCodeTerminalConfig
---@param cmd_string string
---@param env_table table
---@param focus_term boolean|nil
---@return boolean success
local function fallback_open(cfg, cmd_string, env_table, focus_term)
	return native().open(cmd_string, env_table, cfg, focus_term)
end

---@param term_config OpenCodeTerminalConfig
function M.setup(term_config)
	config = term_config
	-- A fresh config is a fresh start: forget any earlier fallback so a newly
	-- available Snacks can take over again.
	delegated = false
end

---@param cmd_string string
---@param env_table table
---@param cfg OpenCodeTerminalConfig
---@param focus_term boolean|nil
---@return boolean success
function M.open(cmd_string, env_table, cfg, focus_term)
	focus_term = utils.normalize_focus(focus_term)
	if delegated then
		return native().open(cmd_string, env_table, cfg, focus_term)
	end

	local snacks = snacks_module()
	if not snacks then
		return fallback_open(cfg, cmd_string, env_table, focus_term)
	end

	if buf_valid(terminal) then
		return show(terminal, cfg, focus_term)
	end

	local opts = build_opts(cfg, env_table, focus_term)
	local ok, term = pcall(snacks.terminal.open, utils.parse_command(cmd_string), opts)
	if not ok or not term then
		vim.notify(
			"opencode.nvim: Snacks.terminal.open() failed — falling back to the native provider.",
			vim.log.levels.WARN
		)
		return fallback_open(cfg, cmd_string, env_table, focus_term)
	end

	if not buf_valid(term) then
		vim.notify(
			"opencode.nvim: Snacks returned an invalid terminal handle — falling back to the native provider.",
			vim.log.levels.WARN
		)
		return fallback_open(cfg, cmd_string, env_table, focus_term)
	end

	terminal = term
	setup_events(term, cfg)
	utils.adopt_terminal_buffer(term.buf, config)
	utils.show_exit_tip(config)

	if focus_term then
		maybe_focus(term, cfg)
	end
	return true
end

---Hide the pane; the TUI process keeps running.
function M.close()
	if delegated then
		return native().close()
	end
	if buf_valid(terminal) then
		hide(terminal)
	end
end

---@param cmd_string string
---@param env_table table
---@param cfg OpenCodeTerminalConfig
function M.simple_toggle(cmd_string, env_table, cfg)
	if delegated then
		return native().simple_toggle(cmd_string, env_table, cfg)
	end
	if buf_valid(terminal) then
		if is_visible(terminal) then
			hide(terminal)
		else
			show(terminal, cfg, true)
		end
		return
	end
	M.open(cmd_string, env_table, cfg, true)
end

---@param cmd_string string
---@param env_table table
---@param cfg OpenCodeTerminalConfig
function M.focus_toggle(cmd_string, env_table, cfg)
	if delegated then
		return native().focus_toggle(cmd_string, env_table, cfg)
	end
	if buf_valid(terminal) then
		if not is_visible(terminal) then
			show(terminal, cfg, true)
		elseif terminal.win == vim.api.nvim_get_current_win() then
			hide(terminal)
		else
			focus_win(terminal, nil, cfg)
		end
		return
	end
	M.open(cmd_string, env_table, cfg, true)
end

---Kill the job, close the window and drop the buffer.
function M.stop()
	if delegated then
		return native().stop()
	end
	local term = terminal
	-- Clear state first so a later TermClose cannot clobber a new instance.
	terminal = nil
	if not term then
		return
	end

	local buf = term.buf
	local chan = buf and vim.api.nvim_buf_is_valid(buf) and vim.b[buf].terminal_job_id
	if chan and chan > 0 then
		pcall(vim.fn.jobstop, chan)
	end
	if term.win and vim.api.nvim_win_is_valid(term.win) then
		pcall(vim.api.nvim_win_close, term.win, true)
	end
	if buf and vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
end

---@return number|nil
function M.get_active_bufnr()
	if delegated then
		return native().get_active_bufnr()
	end
	if buf_valid(terminal) then
		return terminal.buf
	end
	return nil
end

---@return boolean
function M.is_visible()
	if delegated then
		return native().is_visible()
	end
	return is_visible(terminal)
end

---@return boolean
function M.is_available()
	return is_available()
end

---@type OpenCodeTerminalProvider
return M
