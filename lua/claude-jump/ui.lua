-- Floating window management.
local M = {}
local api = vim.api

--- Open a new floating scratch window.
--- Returns a state table: { buf, win, width, height }
function M.open(config)
  local cfg = config.ui or {}
  local width  = math.max(60, math.floor(vim.o.columns * (cfg.width  or 0.58)))
  local height = math.max(12, math.floor(vim.o.lines   * (cfg.height or 0.68)))
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width)  / 2)

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype  = "claude-jump-output"

  local win = api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = row,
    col       = col,
    width     = width,
    height    = height,
    style     = "minimal",
    border    = cfg.border or "rounded",
    title     = "  Claude Jump  ",
    title_pos = "center",
  })

  vim.wo[win].wrap       = true
  vim.wo[win].cursorline = true
  vim.wo[win].number     = false

  -- Highlight [path:line] markers so jumpable lines stand out.
  api.nvim_buf_call(buf, function()
    vim.cmd([[syntax match ClaudeJumpLoc /\[[^][:]\+:\d\+\]/]])
    vim.cmd([[highlight default link ClaudeJumpLoc Special]])
  end)

  -- q / Esc closes the window
  local function close()
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  end
  for _, k in ipairs({ "q", "<Esc>" }) do
    api.nvim_buf_set_keymap(buf, "n", k, "", { noremap = true, silent = true, callback = close })
  end

  return { buf = buf, win = win, width = width, height = height }
end

--- Replace lines [0, count) with `lines`.
function M.set_lines(state, lines)
  if not api.nvim_buf_is_valid(state.buf) then return end
  api.nvim_buf_set_lines(state.buf, 0, #lines, false, lines)
end

--- Append one line and scroll to bottom.
function M.append(state, line)
  if not api.nvim_buf_is_valid(state.buf) then return end
  local n = api.nvim_buf_line_count(state.buf)
  api.nvim_buf_set_lines(state.buf, n, n, false, { line })
  if api.nvim_win_is_valid(state.win) then
    api.nvim_win_set_cursor(state.win, { api.nvim_buf_line_count(state.buf), 0 })
  end
end

--- Append multiple lines at once.
function M.append_block(state, lines)
  for _, l in ipairs(lines) do
    M.append(state, l)
  end
end

--- Add a keymap to the window's buffer.
function M.bind(state, key, fn)
  if not api.nvim_buf_is_valid(state.buf) then return end
  api.nvim_buf_set_keymap(state.buf, "n", key, "", { noremap = true, silent = true, callback = fn })
end

function M.close(state)
  if api.nvim_win_is_valid(state.win) then
    api.nvim_win_close(state.win, true)
  end
end

function M.divider(state)
  M.append(state, string.rep("─", state.width - 2))
end

return M
