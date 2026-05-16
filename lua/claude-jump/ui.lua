-- Floating window management around a single persistent Claude buffer.
--
-- The buffer "claude://output" is created once and kept alive with
-- bufhidden=hide. Windows come and go; the buffer does not. This lets
-- the user close the float, jump around, and re-open it later with
-- M.focus() to see the previous run's output.
local M = {}
local api = vim.api

local BUF_NAME = "claude://output"

-- ── Buffer lifecycle ──────────────────────────────────────────────────────────

local function find_buf()
  for _, b in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(b) and api.nvim_buf_get_name(b) == BUF_NAME then
      return b
    end
  end
  return nil
end

local function find_win(buf)
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(w) and api.nvim_win_get_buf(w) == buf then
      return w
    end
  end
  return nil
end

local function ensure_buf()
  local buf = find_buf()
  if buf then return buf end

  buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(buf, BUF_NAME)
  vim.bo[buf].bufhidden  = "hide"   -- keep alive when all windows close
  vim.bo[buf].filetype   = "claude-jump-output"
  vim.bo[buf].modifiable = true
  vim.bo[buf].buflisted  = false

  -- [path:line] markers become visually distinct; users know they're jumpable.
  api.nvim_buf_call(buf, function()
    vim.cmd([[syntax match ClaudeJumpLoc /\[[^][:]\+:\d\+\]/]])
    vim.cmd([[highlight default link ClaudeJumpLoc Special]])
  end)

  return buf
end

-- ── Window helpers ────────────────────────────────────────────────────────────

local function open_win(buf, ui_cfg)
  local width  = math.max(60, math.floor(vim.o.columns * (ui_cfg.width  or 0.58)))
  local height = math.max(12, math.floor(vim.o.lines   * (ui_cfg.height or 0.68)))
  local row    = math.floor((vim.o.lines   - height) / 2)
  local col    = math.floor((vim.o.columns - width)  / 2)

  local win = api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = row,
    col       = col,
    width     = width,
    height    = height,
    style     = "minimal",
    border    = ui_cfg.border or "rounded",
    title     = "  Claude Jump  ",
    title_pos = "center",
  })

  vim.wo[win].wrap       = true
  vim.wo[win].cursorline = true
  vim.wo[win].number     = false

  return win, width, height
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Start a new Claude run.
--- Reuses the persistent buffer (clears it), closes any existing window,
--- opens a fresh float. Returns state = {buf, win, width, height}.
function M.open(config)
  local ui_cfg = config.ui or {}
  local buf    = ensure_buf()

  -- Close existing window on this buffer, if any.
  local old_win = find_win(buf)
  if old_win then api.nvim_win_close(old_win, true) end

  -- Clear for the new run.
  api.nvim_buf_set_lines(buf, 0, -1, false, {})

  local win, width, height = open_win(buf, ui_cfg)

  -- q / Esc hides the window; buffer stays alive for M.focus() later.
  -- Setting the keymap on each open() call updates the closure's `win`
  -- reference to the current window handle.
  local function hide()
    if api.nvim_win_is_valid(win) then api.nvim_win_close(win, true) end
  end
  for _, k in ipairs({ "q", "<Esc>" }) do
    api.nvim_buf_set_keymap(buf, "n", k, "", { noremap = true, silent = true, callback = hide })
  end

  return { buf = buf, win = win, width = width, height = height }
end

--- Re-open (or focus) the Claude buffer without clearing it.
--- Call this after jumping to come back and inspect the previous output.
--- Returns true if there was a buffer to show, false if nothing exists yet.
function M.focus(config)
  local buf = find_buf()
  if not buf then return false end

  local win = find_win(buf)
  if win and api.nvim_win_is_valid(win) then
    api.nvim_set_current_win(win)
  else
    open_win(buf, (config or {}).ui or {})
  end
  return true
end

--- Replace the first `n` lines of the buffer with `lines`.
function M.set_lines(state, lines)
  if not api.nvim_buf_is_valid(state.buf) then return end
  api.nvim_buf_set_lines(state.buf, 0, #lines, false, lines)
end

--- Append one line and scroll the window to the bottom.
function M.append(state, line)
  if not api.nvim_buf_is_valid(state.buf) then return end
  local n = api.nvim_buf_line_count(state.buf)
  api.nvim_buf_set_lines(state.buf, n, n, false, { line })
  if api.nvim_win_is_valid(state.win) then
    api.nvim_win_set_cursor(state.win, { api.nvim_buf_line_count(state.buf), 0 })
  end
end

function M.append_block(state, lines)
  for _, l in ipairs(lines) do M.append(state, l) end
end

--- Set or replace a normal-mode keymap on the buffer.
--- Calling again with the same key replaces the previous binding.
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
