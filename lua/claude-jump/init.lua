local M = {}

local config_m  = require("claude-jump.config")
local context_m = require("claude-jump.context")
local claude_m  = require("claude-jump.claude")
local ui_m      = require("claude-jump.ui")
local parser_m  = require("claude-jump.parser")

local _cfg        = {}
local _active_job = nil

-- ── Design philosophy ────────────────────────────────────────────────────────
--
-- The plugin enforces one thing only: the I/O contract with Claude.
-- Everything semantic — what's a definition, what depth is useful, what's
-- worth showing — is Claude's call. The contract has two pieces:
--
--   1. `[path:line]` is the universal "jumpable location" marker.
--      Anywhere Claude writes one, the user can press <CR> on that line
--      to jump there.
--
--   2. For jump-to-definition specifically, Claude ends with the sentinel
--      "---JUMP-RESULT---" on its own line, immediately followed by a
--      JSON object — the canonical answer the plugin uses for auto-jump.
--
-- That's it. No depth knobs, no sibling limits, no per-language heuristics.
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Prompts ──────────────────────────────────────────────────────────────────

local function fmt_jump_prompt(ctx)
  return ([[
You are helping a developer navigate a codebase from inside their editor.

## Task
Find where the symbol `%s` is DEFINED (not just declared).

## Starting point
File : %s
Line : %d  Column: %d
Lang : %s

## A few lines around the cursor (cursor annotated)
```%s
%s
```

## How to work
- Use your tools freely (grep, read_file, list_directory, …). Read-only.
- Use whatever depth of exploration you think the case warrants — fast for
  simple lookups, more thorough for templated/overloaded/macro-heavy code.
- Whenever you reference a code location in your output, write it as
  `[path:line]` (literal square brackets). Those become jumpable links in
  the user's window — so the user gets value from your reasoning too.

## Output contract
End with EXACTLY one sentinel line, then one JSON object, then nothing:

%s
{"file": "<path>", "line": <number>, "confidence": "<high|medium|low>", "explanation": "<one sentence>"}

If you genuinely cannot find it:

%s
{"file": null, "line": null, "confidence": "low", "explanation": "<why>"}
]]):format(
    ctx.symbol,
    ctx.filepath, ctx.row, ctx.col, ctx.filetype,
    ctx.filetype, ctx.context,
    parser_m.SENTINEL, parser_m.SENTINEL
  )
end

local function fmt_callstack_prompt(ctx)
  return ([[
You are helping a developer understand code flow from inside their editor.

## Task
Build the most informative call hierarchy for the symbol `%s`.

## Starting point
File : %s
Line : %d
Lang : %s

## A few lines around the cursor (cursor annotated)
```%s
%s
```

## How to work
- Use your tools freely (grep, read_file, list_directory, …). Read-only.
- Use your judgment for depth and breadth. The output renders in a small
  floating window (~30 lines visible), so prefer signal over completeness:
  show the slice that best helps the user understand how `%s` fits into the
  codebase. When a fan-out gets noisy, truncate and say "... N more".
- Annotate every confirmed location as `[path:line]` — those become
  jumpable links in the user's window. Mark uncertain nodes with `[?]`.

## Output format
Render a single ASCII tree. Callers above, callees below the current symbol.
No sentinel, no JSON — the tree itself is the deliverable. Example shape:

  caller_top()  [a.h:10]
  └── caller_mid()  [b.h:44]
      └── %s()  [current]
              ├── helper_A()  [c.h:8]
              └── helper_B()  [c.h:20]
]]):format(
    ctx.symbol,
    ctx.filepath, ctx.row, ctx.filetype,
    ctx.filetype, ctx.context,
    ctx.symbol, ctx.symbol
  )
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function short_path(p)
  return vim.fn.fnamemodify(p, ":~:.")
end

local function cancel_active()
  if _active_job then
    claude_m.stop(_active_job)
    _active_job = nil
  end
end

local function do_jump(result, source_win, source_filepath)
  if not result or not result.file then
    vim.notify("claude-jump: no location to jump to", vim.log.levels.WARN)
    return
  end

  local resolved = parser_m.resolve_path(result.file, source_filepath)
  if not resolved then
    vim.notify("claude-jump: cannot find file: " .. result.file, vim.log.levels.WARN)
    return
  end

  if source_win and vim.api.nvim_win_is_valid(source_win) then
    vim.api.nvim_set_current_win(source_win)
  end

  vim.cmd("edit " .. vim.fn.fnameescape(resolved))
  local line = math.max(1, result.line or 1)
  pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  vim.cmd("normal! zz")
end

--- Bind <CR> in the floating window to jump to the `[path:line]` marker on
--- the current line, if any. This is the universal navigation primitive.
local function bind_inline_jump(state, source_win, source_filepath)
  ui_m.bind(state, "<CR>", function()
    local row = vim.api.nvim_win_get_cursor(state.win)[1]
    local line = (vim.api.nvim_buf_get_lines(state.buf, row - 1, row, false))[1] or ""
    local loc = parser_m.location_on_line(line)
    if loc then
      ui_m.close(state)
      do_jump(loc, source_win, source_filepath)
    else
      vim.notify("claude-jump: no [path:line] marker on this line", vim.log.levels.INFO)
    end
  end)
end

-- ── Core runner ──────────────────────────────────────────────────────────────

local function run_with_ui(prompt, header_lines, on_done_extra)
  local source_win      = vim.api.nvim_get_current_win()
  local source_filepath = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())

  local state = ui_m.open(_cfg)
  ui_m.set_lines(state, header_lines)

  -- Universal navigation: any line containing [path:line] is jumpable.
  bind_inline_jump(state, source_win, source_filepath)

  cancel_active()

  _active_job = claude_m.run(
    prompt, _cfg,

    function(line)
      ui_m.append(state, line)
    end,

    function(exit_code, full_output, err_output)
      _active_job = nil

      ui_m.divider(state)

      if exit_code ~= 0 then
        ui_m.append_block(state, {
          "  [ERROR] Claude exited with code " .. exit_code,
          err_output ~= "" and ("  " .. err_output) or "",
          "",
          "  [q/Esc] Close",
        })
        return
      end

      on_done_extra(state, source_win, source_filepath, full_output)
    end
  )
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Jump to the definition of the symbol under the cursor.
function M.jump()
  local ctx = context_m.get({ context_lines = _cfg.context_lines })
  if ctx.symbol == "" then
    vim.notify("claude-jump: no symbol under cursor", vim.log.levels.WARN)
    return
  end

  local header = {
    ("  Symbol : %s"):format(ctx.symbol),
    ("  From   : %s  line %d"):format(short_path(ctx.filepath), ctx.row),
    ("  Status : asking Claude…"),
    "",
  }

  run_with_ui(fmt_jump_prompt(ctx), header, function(state, source_win, source_filepath, full_output)
    local result = parser_m.definition(full_output)

    if result and result.file then
      ui_m.append_block(state, {
        "",
        ("  → [%s:%d]   confidence: %s"):format(result.file, result.line or 0, result.confidence or "?"),
        result.explanation ~= "" and ("    " .. result.explanation) or "",
        "",
        "  [Enter] on any [path:line] → jump      [q/Esc] close",
      })

      -- Move cursor to the result line so <Enter> Just Works.
      local total = vim.api.nvim_buf_line_count(state.buf)
      pcall(vim.api.nvim_win_set_cursor, state.win, { total - 2, 0 })

      if _cfg.auto_jump and result.confidence == "high" then
        vim.defer_fn(function()
          if vim.api.nvim_win_is_valid(state.win) then
            ui_m.close(state)
            do_jump(result, source_win, source_filepath)
          end
        end, 600)
      end
    else
      ui_m.append_block(state, {
        "",
        "  Could not determine a single definition location.",
        "  Any [path:line] above is still jumpable via [Enter].",
        "  [q/Esc] Close",
      })
    end
  end)
end

--- Show the call hierarchy for the symbol under the cursor.
function M.call_stack()
  local ctx = context_m.get({ context_lines = _cfg.context_lines })
  if ctx.symbol == "" then
    vim.notify("claude-jump: no symbol under cursor", vim.log.levels.WARN)
    return
  end

  local header = {
    ("  Call Stack : %s"):format(ctx.symbol),
    ("  From       : %s  line %d"):format(short_path(ctx.filepath), ctx.row),
    ("  Status     : analyzing with Claude…"),
    "",
  }

  run_with_ui(fmt_callstack_prompt(ctx), header, function(state, _, _, _)
    ui_m.append_block(state, {
      "",
      "  [Enter] on any [path:line] → jump      [q/Esc] close",
    })
  end)
end

--- Plugin setup — call from your config with optional overrides.
function M.setup(opts)
  _cfg = config_m.setup(opts)

  local km = _cfg.keymaps or {}
  if km.jump then
    vim.keymap.set("n", km.jump, M.jump, { desc = "Claude Jump: go to definition" })
  end
  if km.call_stack then
    vim.keymap.set("n", km.call_stack, M.call_stack, { desc = "Claude Jump: show call stack" })
  end
end

return M
