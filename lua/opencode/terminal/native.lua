---Native Neovim terminal provider for the opencode TUI.
---
---Owns a plain `termopen` job in a side split. `close`/`hide` never kill the job
---—only `stop` does.
---@module 'opencode.terminal.native'

local M = {}

local utils = require("opencode.utils")

---@type OpenCodeTerminalConfig
local config = require("opencode.terminal").defaults

local bufnr ---@type number|nil
local winid ---@type number|nil
local jobid ---@type number|nil

---Forget every tracked handle.
local function cleanup_state()
	bufnr = nil
	winid = nil
	jobid = nil
end

---Window currently displaying the managed terminal buffer, if any.
---Always returns fresh state: `winid` is updated (or cleared) as a side effect.
---@return number|nil win
local function find_window()
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		winid = nil
		return nil
	end
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
			winid = win
			return win
		end
	end
	winid = nil
	return nil
end

---Is the managed terminal still usable (buffer alive and, if known, job running)?
---Recovers `winid` from the window list; clears all state when unrecoverable.
---@return boolean
local function is_valid()
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		cleanup_state()
		return false
	end

	-- `on_exit` is scheduled, so there is a window where the job is gone but our
	-- state still points at it. Probe the job rather than handing the user a dead
	-- terminal buffer. jobwait returns the exit status, or -1 while still running.
	if jobid and jobid > 0 then
		local ok, waited = pcall(vim.fn.jobwait, { jobid }, 0)
		if ok and type(waited) == "table" and waited[1] ~= nil and waited[1] ~= -1 then
			cleanup_state()
			return false
		end
	end

	find_window() -- recovers winid when the window was replaced/moved
	return true
end

---Open an empty full-height vertical split on the configured side.
---@param cfg OpenCodeTerminalConfig
---@return number win
local function make_split(cfg)
	local width = math.max(20, math.floor(vim.o.columns * cfg.split_width_percentage))
	local modifier = cfg.split_side == "left" and "topleft " or "botright "
	vim.cmd(modifier .. width .. "vsplit")
	local win = vim.api.nvim_get_current_win()
	pcall(vim.api.nvim_win_set_height, win, vim.o.lines)
	-- A bare `vsplit` reuses the current buffer, so `termopen` would turn that
	-- buffer into the terminal: the TUI would show up in two windows and refuses
	-- to run at all on a modified buffer. Start from a scratch buffer instead, and
	-- mark it `wipe` so it disappears once the terminal buffer takes the window.
	vim.api.nvim_win_call(win, function()
		vim.cmd("enew")
		vim.bo.bufhidden = "wipe"
		vim.bo.buflisted = false
	end)
	return win
end

---Put the cursor in the terminal window (and optionally in insert mode).
---@param win number
---@param cfg OpenCodeTerminalConfig
local function focus(win, cfg)
	winid = win
	vim.api.nvim_set_current_win(win)
	if cfg.auto_insert ~= false then
		pcall(vim.cmd, "startinsert")
	end
end

---Re-create a window for the already-running terminal buffer.
---@param cfg OpenCodeTerminalConfig
---@param focus_term boolean|nil
---@return boolean success
local function show_hidden_terminal(cfg, focus_term)
	focus_term = utils.normalize_focus(focus_term)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		cleanup_state()
		return false
	end

	if find_window() then
		if focus_term then
			focus(winid, cfg)
		end
		return true
	end

	local original_win = vim.api.nvim_get_current_win()
	local new_win = make_split(cfg)
	vim.api.nvim_win_set_buf(new_win, bufnr)
	winid = new_win
	-- The window was recreated from scratch: re-assert hygiene/keymaps so a
	-- buffer recovered from another plugin session is still escapable.
	utils.adopt_terminal_buffer(bufnr, config)

	if focus_term then
		focus(new_win, cfg)
	elseif vim.api.nvim_win_is_valid(original_win) then
		vim.api.nvim_set_current_win(original_win)
	end
	return true
end

---Start a new terminal job in a fresh split.
---@param cmd_string string
---@param env_table table
---@param cfg OpenCodeTerminalConfig
---@param focus_term boolean|nil
---@return boolean success
local function open_terminal(cmd_string, env_table, cfg, focus_term)
	focus_term = utils.normalize_focus(focus_term)
	local original_win = vim.api.nvim_get_current_win()
	local new_win = make_split(cfg)

	local job_opts = {
		cwd = cfg.cwd,
		on_exit = function(job_id, _, _)
			vim.schedule(function()
				-- Guard: a *stale* job finishing must not clobber the state of a
				-- freshly spawned terminal.
				if job_id ~= jobid then
					return
				end
				local dead_win = winid
				cleanup_state()
				if cfg.auto_close and dead_win and vim.api.nvim_win_is_valid(dead_win) then
					pcall(vim.api.nvim_win_close, dead_win, true)
				end
			end)
		end,
	}
	-- termopen() rejects an empty `env` table outright, so only pass it when set.
	if env_table and next(env_table) ~= nil then
		job_opts.env = env_table
	end

	-- Spawn without a shell: quoted args survive and bracketed words (e.g.
	-- `--model=x[1m]`) are not glob-expanded by zsh/bash.
	local new_jobid = vim.fn.termopen(utils.parse_command(cmd_string), job_opts)

	if not new_jobid or new_jobid <= 0 then
		vim.notify("opencode.nvim: failed to run " .. cmd_string, vim.log.levels.ERROR)
		if vim.api.nvim_win_is_valid(new_win) then
			pcall(vim.api.nvim_win_close, new_win, true)
		end
		if vim.api.nvim_win_is_valid(original_win) then
			vim.api.nvim_set_current_win(original_win)
		end
		cleanup_state()
		return false
	end

	jobid = new_jobid
	winid = new_win
	bufnr = vim.api.nvim_get_current_buf()
	utils.adopt_terminal_buffer(bufnr, config)

	if focus_term then
		focus(new_win, cfg)
	elseif vim.api.nvim_win_is_valid(original_win) then
		vim.api.nvim_set_current_win(original_win)
	end

	utils.show_exit_tip(config)
	return true
end

---Close the terminal window while keeping the buffer and the job alive.
---@return boolean success false when the window could not be closed
local function hide_terminal()
	local win = find_window()
	if not win then
		return false
	end
	-- `force = false`: close the window, keep the buffer (and running job).
	-- Only forget the window if the close actually happened, otherwise we would
	-- lose track of a window that is still on screen.
	if not pcall(vim.api.nvim_win_close, win, false) then
		vim.notify(
			"opencode.nvim: cannot hide the pane — it is the only window left. Open another window first.",
			vim.log.levels.WARN
		)
		return false
	end
	winid = nil
	return true
end

---Find an opencode terminal buffer we lost track of (e.g. after a session reload
---of this module). Matches `buftype == "terminal"` on the command name.
---@return number|nil buf
---@return number|nil win
local function find_existing_opencode_terminal()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "terminal" then
			local name = vim.api.nvim_buf_get_name(buf)
			if name:match("opencode") then
				for _, w in ipairs(vim.api.nvim_list_wins()) do
					if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == buf then
						return buf, w
					end
				end
			end
		end
	end
	return nil, nil
end

---Bring the terminal into view, starting it when needed.
---@param cfg OpenCodeTerminalConfig
---@param focus_term boolean|nil
---@return boolean success
local function show_or_spawn(cmd_string, env_table, cfg, focus_term)
	if is_valid() then
		return show_hidden_terminal(cfg, focus_term)
	end

	local existing_buf, existing_win = find_existing_opencode_terminal()
	if existing_buf and existing_win then
		bufnr = existing_buf
		winid = existing_win
		utils.adopt_terminal_buffer(bufnr, config)
		if focus_term then
			focus(existing_win, cfg)
		end
		return true
	end

	return open_terminal(cmd_string, env_table, cfg, focus_term)
end

---@param term_config OpenCodeTerminalConfig
function M.setup(term_config)
	config = term_config
end

---@param cmd_string string
---@param env_table table
---@param cfg OpenCodeTerminalConfig
---@param focus_term boolean|nil
---@return boolean success
function M.open(cmd_string, env_table, cfg, focus_term)
	return show_or_spawn(cmd_string, env_table, cfg, focus_term)
end

---Hide the pane. The TUI process keeps running — use `stop` to kill it.
function M.close()
	if is_valid() then
		hide_terminal()
	end
end

---Toggle visibility regardless of focus.
---@param cmd_string string
---@param env_table table
---@param cfg OpenCodeTerminalConfig
function M.simple_toggle(cmd_string, env_table, cfg)
	if is_valid() then
		if find_window() then
			hide_terminal()
		else
			show_hidden_terminal(cfg, true)
		end
		return
	end
	show_or_spawn(cmd_string, env_table, cfg, true)
end

---Focus the terminal when it is hidden or unfocused; hide it when focused.
---@param cmd_string string
---@param env_table table
---@param cfg OpenCodeTerminalConfig
function M.focus_toggle(cmd_string, env_table, cfg)
	if is_valid() then
		local win = find_window()
		if not win then
			show_hidden_terminal(cfg, true)
		elseif win == vim.api.nvim_get_current_win() then
			hide_terminal()
		else
			focus(win, cfg)
		end
		return
	end
	show_or_spawn(cmd_string, env_table, cfg, true)
end

---Kill the job, close the window and delete the buffer.
function M.stop()
	-- Refresh winid first so we act on the window that is actually showing the
	-- buffer, not a stale id (E5555 would otherwise abort the whole stop).
	local victim_win = find_window() or winid
	local victim_buf, victim_job = bufnr, jobid
	-- Clear state first: the resulting on_exit is then a stale job and its guard
	-- makes it a no-op, so it cannot clobber a terminal spawned in the meantime.
	cleanup_state()

	if victim_job and victim_job > 0 then
		pcall(vim.fn.jobstop, victim_job)
	end
	if victim_win and vim.api.nvim_win_is_valid(victim_win) then
		pcall(vim.api.nvim_win_close, victim_win, true)
	end
	if victim_buf and vim.api.nvim_buf_is_valid(victim_buf) then
		pcall(vim.api.nvim_buf_delete, victim_buf, { force = true })
	end
end

---@return number|nil
function M.get_active_bufnr()
	if is_valid() then
		return bufnr
	end
	return nil
end

---@return boolean
function M.is_visible()
	return find_window() ~= nil
end

---@return boolean
function M.is_available()
	return true
end

---@type OpenCodeTerminalProvider
return M
