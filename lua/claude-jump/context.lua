-- Gathers cursor context to send to Claude.
local M = {}

function M.get(opts)
  local context_lines = (opts or {}).context_lines or 60

  local bufnr = vim.api.nvim_get_current_buf()
  local win   = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1]   -- 1-indexed
  local col = cursor[2]   -- 0-indexed

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype
  local symbol   = vim.fn.expand("<cword>")

  local total   = vim.api.nvim_buf_line_count(bufnr)
  local s       = math.max(1, row - context_lines)
  local e       = math.min(total, row + context_lines)
  local lines   = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)

  -- Tag the cursor line so Claude knows exactly where we are.
  local rel = row - s + 1  -- 1-indexed within the slice
  if lines[rel] then
    lines[rel] = lines[rel] .. "  -- <<< CURSOR HERE (symbol: " .. symbol .. ")"
  end

  return {
    symbol           = symbol,
    filepath         = filepath,
    filetype         = filetype ~= "" and filetype or "cpp",
    row              = row,
    col              = col,
    context_start    = s,
    context_end      = e,
    context          = table.concat(lines, "\n"),
    total_lines      = total,
  }
end

return M
