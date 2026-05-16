local M = {}

M.defaults = {
  -- Claude CLI executable
  claude_cmd = "claude",
  -- Extra flags forwarded to the CLI
  claude_flags = { "--print" },
  -- Lines of immediate context sent on each side of the cursor. Just enough
  -- for Claude to recognise the symbol type — Claude does the real search
  -- with its own tools.
  context_lines = 5,
  -- Default keymaps (set to false to disable)
  keymaps = {
    jump       = "gc",
    call_stack = "gC",
    focus      = nil,   -- e.g. "g." — re-open Claude window after jumping away
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
