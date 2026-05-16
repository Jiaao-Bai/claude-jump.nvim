local M = {}

local config_m  = require("claude-jump.config")
local context_m = require("claude-jump.context")
local claude_m  = require("claude-jump.claude")
local ui_m      = require("claude-jump.ui")
local parser_m  = require("claude-jump.parser")

local _cfg        = {}
local _active_job = nil

-- ── Prompts ──────────────────────────────────────────────────────────────────

local JUMP_PROMPT = [[
You are an expert C++ engineer helping navigate a codebase.

## Task
Find the DEFINITION (not a forward declaration) of the symbol "%s".

## Where we are
File : %s
Line : %d  Column: %d
Lang : %s

## Code context  (lines %d–%d; cursor annotated)
```%s
%s
```

## Instructions
1. Use your tools (read_file, grep_ast, list_directory, etc.) to locate the definition in the project.
2. Only READ files — do NOT modify anything.
3. For C++ templates / CUTLASS-style deep instantiations, check .cuh / .h / .hpp headers.
4. When confident, output EXACTLY this JSON (last thing you write, nothing after):

```json
{"file": "<path>", "line": <number>, "confidence": "<high|medium|low>", "explanation": "<one sentence>"}
```

If you truly cannot determine the location:
```json
{"file": null, "line": null, "confidence": "low", "explanation": "<reason>"}
```
]]

local CALLSTACK_PROMPT = [[
You are an expert C++ engineer helping understand code flow.

## Task
Analyze the call hierarchy for the symbol "%s".

## Where we are
File : %s
Line : %d
Lang : %s

## Code context  (lines %d–%d; cursor annotated)
```%s
%s
```

## Instructions
1. Use your tools (read_file, grep_ast, list_directory, etc.) to trace the call graph.
2. Only READ files — do NOT modify anything.
3. Show:
   • CALLERS  — what calls "%s" (upstream callers, as deep as useful)
   • CALLEES  — what "%s" itself calls (downstream, as deep as useful)
4. Format as an ASCII tree.  Include [file:line] for every node you can confirm.

Example format:
  caller_A()  [gemm.h:120]
  └── caller_B()  [mma.h:44]
      └── %s()  [current]
              ├── helper_X()  [utils.h:88]
              └── helper_Y()  [utils.h:102]

Mark uncertain nodes with [?].
]]

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function fmt_jump_prompt(ctx)
  return JUMP_PROMPT:format(
    ctx.symbol,
    ctx.filepath, ctx.row, ctx.col, ctx.filetype,
    ctx.context_start, ctx.context_end,
    ctx.filetype, ctx.context,
    ctx.filetype
  )
end

local function fmt_callstack_prompt(ctx)
  return CALLSTACK_PROMPT:format(
    ctx.symbol,
    ctx.filepath, ctx.row, ctx.filetype,
    ctx.context_start, ctx.context_end,
    ctx.filetype, ctx.context,
    ctx.symbol, ctx.symbol, ctx.symbol
  )
end

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
    vim.notify("claude-jump: no definition location found", vim.log.levels.WARN)
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

-- ── Core runner (shared by jump + call_stack) ────────────────────────────────

local function run_with_ui(prompt, header_lines, on_done_extra)
  local source_win      = vim.api.nvim_get_current_win()
  local source_filepath = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())

  local state = ui_m.open(_cfg)
  ui_m.set_lines(state, header_lines)

  cancel_active()

  _active_job = claude_m.run(
    prompt, _cfg,

    -- on_line: stream each output line into the window
    function(line)
      ui_m.append(state, line)
    end,

    -- on_done: called once Claude exits
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
    ("  File   : %s  line %d"):format(short_path(ctx.filepath), ctx.row),
    ("  Status : asking Claude…"),
    "",
  }

  run_with_ui(fmt_jump_prompt(ctx), header, function(state, source_win, source_filepath, full_output)
    local result = parser_m.definition(full_output)

    if result and result.file then
      ui_m.append_block(state, {
        "",
        ("  → %s : %d"):format(result.file, result.line or 0),
        ("    confidence : %s"):format(result.confidence or "?"),
        result.explanation ~= "" and ("    " .. result.explanation) or "",
        "",
        "  [Enter] Jump    [q/Esc] Cancel",
      })

      ui_m.bind(state, "<CR>", function()
        ui_m.close(state)
        do_jump(result, source_win, source_filepath)
      end)

      -- Auto-jump when confidence is high and user opted in
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
        "  Could not determine definition location.",
        "  [q/Esc] Close",
      })
    end
  end)
end

--- Show the call-stack / call-hierarchy for the symbol under the cursor.
function M.call_stack()
  local ctx = context_m.get({ context_lines = _cfg.context_lines })
  if ctx.symbol == "" then
    vim.notify("claude-jump: no symbol under cursor", vim.log.levels.WARN)
    return
  end

  local header = {
    ("  Call Stack : %s"):format(ctx.symbol),
    ("  File       : %s  line %d"):format(short_path(ctx.filepath), ctx.row),
    ("  Status     : analyzing with Claude…"),
    "",
  }

  run_with_ui(fmt_callstack_prompt(ctx), header, function(state, _, _, _)
    ui_m.append_block(state, { "", "  [q/Esc] Close" })
  end)
end

--- Plugin setup — call this from your config with optional overrides.
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
