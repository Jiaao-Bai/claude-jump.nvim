# claude-jump.nvim

AI-powered go-to-definition for Neovim, powered by Claude Code.  
For when ctags and clangd give up — think CUTLASS-level C++ template metaprogramming.

## Design philosophy

> **The plugin enforces the I/O contract. Claude does everything else.**

Concretely:

- No depth knobs, no sibling limits, no per-language heuristics. Claude has
  tools — let it decide what's worth showing.
- The plugin only locks down two things in the prompt:
  1. `[path:line]` is the universal "jumpable location" marker. Anywhere Claude
     writes one, `<CR>` on that line in the floating window jumps there.
  2. For `:ClaudeJump`, Claude ends with a sentinel `---JUMP-RESULT---` followed
     by a single JSON object so the plugin can auto-jump on high confidence.

Everything else — search depth, which files to read, how wide to fan out a
call tree, what's signal vs. noise — is Claude's call.

## Why this plugin

`clangd` and `ctags` choke on heavily templated C++ (partial specialisations,
SFINAE chains, CUTLASS tile iterators, …). This plugin pipes the symbol under
your cursor to Claude Code, which uses `grep`, `read_file`, etc. to find the
definition across headers and tells the editor where to jump.

Use it as a *fallback* when your normal LSP gives up — not as a daily driver.

## Requirements

- Neovim 0.9+
- [Claude Code CLI](https://docs.anthropic.com/claude-code) installed and on `$PATH`

No API key wrangling — Claude Code handles auth.

## Installation

```lua
-- lazy.nvim
{
  "jiaao-bai/claude-jump.nvim",
  config = function() require("claude-jump").setup() end,
}
```

## Usage

| Key  | Command            | What it does                                                     |
|------|--------------------|------------------------------------------------------------------|
| `gc` | `:ClaudeJump`      | Find & jump to the definition of the symbol under the cursor     |
| `gC` | `:ClaudeCallStack` | Render the call hierarchy (callers + callees) as a jumpable tree |

Inside either floating window:

- **`<CR>`** — jump to the `[path:line]` on the current line (works on
  *any* line that contains a marker — the result line, reasoning lines,
  call-tree nodes, anything)
- **`q` / `<Esc>`** — close

For `:ClaudeJump` the cursor is parked on the result line by default, so
`<CR>` Just Works. For `:ClaudeCallStack` move the cursor to whichever node
in the tree you want to visit, then `<CR>`.

## Configuration

```lua
require("claude-jump").setup({
  claude_cmd    = "claude",            -- CLI binary
  claude_flags  = { "--print" },       -- non-interactive mode
  context_lines = 5,                   -- lines of immediate cursor context
  keymaps       = { jump = "gc", call_stack = "gC" },  -- set to false to disable
  ui            = { width = 0.58, height = 0.68, border = "rounded" },
  auto_jump     = false,               -- auto-jump when confidence == "high"
})
```

That's all the knobs. By design.

## How it works

```
gc pressed
  │
  ├─ Capture cursor: symbol, filepath, line, ±5 lines for orientation
  │
  ├─ Build prompt → pipe to  claude --print  via stdin  (async, non-blocking)
  │
  ├─ Float streams Claude's live output: tool calls, file reads, reasoning,
  │  all annotated with [path:line] markers
  │
  ├─ Claude finishes with the sentinel + JSON answer
  │
  └─ <Enter> on any [path:line] line in the float → edit + jump + zz
```

Claude runs with its full tool suite, so it can `grep` the project, `read_file`
headers, traverse `#include` chains, reason about SFINAE / concept constraints
— whatever the case warrants.

## Call-stack view example

```
  top_caller()  [a.h:10]
  └── mid_caller()  [b.h:44]
      └── MmaAtomShape()  [current]
              ├── Layout::stride()   [layout.h:88]
              └── TensorRef::data()  [tensor_ref.h:102]
```

Every `[file:line]` is jumpable. Uncertain nodes are marked `[?]`.

## Tips

- Open Neovim from the project root so Claude resolves relative paths cleanly.
- Set `auto_jump = true` if you trust Claude's high-confidence hits.
- This is a *fallback* tool. For everyday navigation, your LSP is faster.
