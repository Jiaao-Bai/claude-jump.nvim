local M = {}

M.defaults = {
  -- Claude CLI executable
  claude_cmd = "claude",
  -- Extra flags passed after the command (before the prompt)
  claude_flags = { "--print" },
  -- Lines of code to send on each side of the cursor
  context_lines = 60,
  -- Default keymaps (set to false to disable)
  keymaps = {
    jump = "gc",
    call_stack = "gC",
  },
  -- Floating window appearance
  ui = {
    width = 0.58,
    height = 0.68,
    border = "rounded",
  },
  -- Auto-jump without pressing Enter when confidence == "high"
  auto_jump = false,
}

function M.setup(opts)
  return vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
