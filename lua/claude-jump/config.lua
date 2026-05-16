local M = {}

M.defaults = {
  -- Claude CLI executable
  claude_cmd = "claude",
  -- Extra flags passed after the command (before the prompt)
  claude_flags = { "--print" },
  -- Lines sent on each side of the cursor — just enough for Claude to
  -- recognise the symbol type; Claude uses its own tools for the real search.
  context_lines = 5,
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
  -- Call-stack depth limits
  call_stack = {
    caller_depth = 3,   -- how many levels of callers to show above the symbol
    callee_depth = 3,   -- how many levels of callees to show below the symbol
    max_siblings = 5,   -- max nodes shown per level before truncating
  },
}

function M.setup(opts)
  return vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
