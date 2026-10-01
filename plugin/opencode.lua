if vim.fn.has("nvim-0.8.0") ~= 1 then
  vim.api.nvim_err_writeln("opencode.nvim requires Neovim >= 0.8.0")
  return
end

if vim.g.loaded_opencode then
  return
end
vim.g.loaded_opencode = 1

--- Set `vim.g.opencode_auto_setup = { ... }` before startup to run `setup()`
--- with those options automatically.
if vim.g.opencode_auto_setup then
  vim.defer_fn(function()
    require("opencode").setup(vim.g.opencode_auto_setup)
  end, 0)
end

if vim.fn.executable("opencode") ~= 1 then
  vim.schedule(function()
    vim.notify(
      "opencode.nvim: `opencode` not found in $PATH — install it from https://opencode.ai",
      vim.log.levels.WARN
    )
  end)
end
