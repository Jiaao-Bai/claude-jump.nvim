if vim.g.loaded_claude_jump then return end
vim.g.loaded_claude_jump = true

vim.api.nvim_create_user_command("ClaudeJump", function()
  require("claude-jump").jump()
end, { desc = "Claude Jump: go to definition of symbol under cursor" })

vim.api.nvim_create_user_command("ClaudeCallStack", function()
  require("claude-jump").call_stack()
end, { desc = "Claude Jump: show call hierarchy for symbol under cursor" })
