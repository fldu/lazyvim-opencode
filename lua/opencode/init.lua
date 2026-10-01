---Minimal OpenCode TUI integration for Neovim.
---
---Opens the `opencode` TUI in a side split and toggles it. Nothing else.
---@module 'opencode'

local M = {}

---@class OpenCodeConfig
---@field terminal_cmd string Command used to launch the TUI.
---@field split_side "left"|"right" Which side the split opens on.
---@field split_width_percentage number Split width as a fraction of the columns.
---@field auto_insert boolean Enter terminal mode when the TUI gains focus.
---@field auto_close boolean Close the split when the TUI process exits.
---@field git_repo_cwd boolean Resolve the cwd from the git root of the current file.
---@field cwd string|nil Force a working directory (wins over `git_repo_cwd`).
---@field keys string[] Normal-mode keymaps registered by `setup()`. Set to `{}` to disable.

---@type OpenCodeConfig
local defaults = {
  terminal_cmd = "opencode",
  split_side = "right",
  split_width_percentage = 0.4,
  auto_insert = true,
  auto_close = true,
  git_repo_cwd = false,
  cwd = nil,
  keys = { "<leader>ac" },
}

---@type OpenCodeConfig
local config = vim.deepcopy(defaults)

local bufnr ---@type number|nil
local winid ---@type number|nil
local jobid ---@type number|nil

---Is the managed terminal buffer still alive?
---@return boolean
local function has_buffer()
  return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

---Window currently displaying the managed terminal buffer, if any.
---@return number|nil win
---@return boolean visible
local function find_window()
  if not has_buffer() then
    return nil, false
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      return win, true
    end
  end
  return nil, false
end

---Working directory used to launch the TUI.
---@return string
local function resolve_cwd()
  if config.cwd then
    return config.cwd
  end

  if config.git_repo_cwd then
    local start = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p:h")
    if start ~= "" and vim.fs and vim.fs.root then
      local root = vim.fs.root(start, ".git")
      if root then
        return root
      end
    end
  end

  return vim.fn.getcwd()
end

---Open an empty vertical split on the configured side and return its window id.
---@return number
local function make_split()
  local width = math.max(20, math.floor(vim.o.columns * config.split_width_percentage))
  local modifier = config.split_side == "left" and "topleft " or "botright "
  vim.cmd(modifier .. width .. "vsplit")
  local win = vim.api.nvim_get_current_win()
  -- A bare `vsplit` reuses the current buffer, so `termopen` would turn that
  -- buffer into the terminal: the TUI would then show up in two windows, and it
  -- refuses to run at all on a modified buffer. Start from a fresh scratch one.
  vim.api.nvim_win_call(win, function()
    vim.cmd("enew")
  end)
  return win
end

---Move the cursor into the TUI window.
---@param win number
local function enter(win)
  winid = win
  vim.api.nvim_set_current_win(win)
  if config.auto_insert then
    vim.cmd("startinsert")
  end
end

---Start the TUI in a fresh split.
---@return boolean success
local function spawn()
  local original_win = vim.api.nvim_get_current_win()
  local new_win = make_split()

  jobid = vim.fn.termopen(config.terminal_cmd, {
    cwd = resolve_cwd(),
    on_exit = function()
      vim.schedule(function()
        local win = find_window() or winid
        bufnr, winid, jobid = nil, nil, nil
        if config.auto_close and win and vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end)
    end,
  })

  if jobid == nil or jobid == 0 then
    vim.notify("opencode.nvim: failed to run " .. config.terminal_cmd, vim.log.levels.ERROR)
    vim.api.nvim_win_close(new_win, true)
    if vim.api.nvim_win_is_valid(original_win) then
      vim.api.nvim_set_current_win(original_win)
    end
    bufnr, winid, jobid = nil, nil, nil
    return false
  end

  bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].bufhidden = "hide"
  winid = new_win

  enter(new_win)
  return true
end

---Re-open a split for a running TUI whose window was hidden.
---@return boolean success
local function reshow()
  if not has_buffer() then
    return false
  end
  local new_win = make_split()
  vim.api.nvim_win_set_buf(new_win, bufnr)
  winid = new_win
  return true
end

---Show and focus the TUI, starting it if needed.
---@return boolean success
function M.open()
  if has_buffer() then
    local win, visible = find_window()
    if visible then
      enter(win)
      return true
    end
    if not reshow() then
      return false
    end
    enter(winid)
    return true
  end
  return spawn()
end

---Hide the split but keep the TUI process running.
function M.close()
  local win = find_window()
  if win then
    -- `force = false` keeps the buffer (and the running job) alive.
    vim.api.nvim_win_close(win, false)
  end
  winid = nil
end

---Kill the TUI process and drop the terminal buffer.
function M.stop()
  if jobid and jobid > 0 then
    pcall(vim.fn.jobstop, jobid)
  end
  local win = find_window()
  if win then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if has_buffer() then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  bufnr, winid, jobid = nil, nil, nil
end

---Focus the TUI if hidden or in another window, otherwise hide it.
function M.toggle()
  local win, visible = find_window()

  if visible then
    if win == vim.api.nvim_get_current_win() then
      M.close()
    else
      enter(win)
    end
    return
  end

  if has_buffer() then
    reshow()
    enter(winid)
  else
    spawn()
  end
end

---@return boolean
function M.is_visible()
  local _, visible = find_window()
  return visible
end

---@return number|nil
function M.get_bufnr()
  return has_buffer() and bufnr or nil
end

local function create_commands()
  vim.api.nvim_create_user_command("Opencode", M.toggle, { desc = "Toggle the opencode TUI" })
  vim.api.nvim_create_user_command("OpencodeFocus", M.open, { desc = "Show/focus the opencode TUI" })
  vim.api.nvim_create_user_command("OpencodeStop", M.stop, { desc = "Stop the opencode TUI" })
end

---@param opts OpenCodeConfig|nil
---@return OpenCodeConfig
function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  create_commands()
  for _, lhs in ipairs(config.keys or {}) do
    vim.keymap.set("n", lhs, "<cmd>Opencode<cr>", { desc = "Toggle opencode", silent = true })
  end
  return config
end

return M
