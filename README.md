# claude-jump.nvim

AI-powered go-to-definition for Neovim, powered by Claude Code.  
For when ctags and clangd give up — think CUTLASS-level C++ template metaprogramming.

## Why

`clangd` and `ctags` choke on heavily templated C++ (partial specialisations,
SFINAE chains, CUTLASS tile iterators, …).  This plugin sends the symbol under
your cursor plus its surrounding context to Claude Code, which uses its tools
(`grep_ast`, `read_file`, …) to actually *find* the definition across headers,
and then jumps you there.

## Requirements

- Neovim 0.9+
- [Claude Code CLI](https://docs.anthropic.com/claude-code) installed and on `$PATH`

No API key wrangling needed — Claude Code handles auth.

## Installation

### lazy.nvim

```lua
{
  "jiaao-bai/claude-jump.nvim",
  config = function()
    require("claude-jump").setup()
  end,
}
```

### packer.nvim

```lua
use {
  "jiaao-bai/claude-jump.nvim",
  config = function()
    require("claude-jump").setup()
  end,
}
```

## Usage

| Key  | Command            | Action                                       |
|------|--------------------|----------------------------------------------|
| `gc` | `:ClaudeJump`      | Jump to definition of symbol under cursor    |
| `gC` | `:ClaudeCallStack` | Show call hierarchy (callers + callees) tree |

Both commands open a floating window that streams Claude's reasoning live.  
Press `<Enter>` to jump, `q` / `<Esc>` to cancel.

## Configuration

```lua
require("claude-jump").setup({
  -- Claude CLI binary (must be on PATH)
  claude_cmd = "claude",

  -- Flags forwarded to the CLI
  claude_flags = { "--print" },

  -- Lines of code sent on each side of the cursor (larger = more context = slower)
  context_lines = 60,

  -- Keymaps (set to false to disable a binding)
  keymaps = {
    jump       = "gc",
    call_stack = "gC",
  },

  -- Floating window size (fraction of screen)
  ui = {
    width  = 0.58,
    height = 0.68,
    border = "rounded",  -- see :h nvim_open_win for other styles
  },

  -- Auto-jump when Claude says confidence == "high" (skips the Enter prompt)
  auto_jump = false,
})
```

## How it works

```
gc pressed
  │
  ├─ Capture: symbol, filepath, line, ±60 lines of context
  │
  ├─ Build prompt → pipe to  claude --print  via stdin (async, non-blocking)
  │
  ├─ Floating window streams Claude's live output
  │   (tool calls, file reads, reasoning all visible)
  │
  ├─ On exit: parse last JSON block  {"file":…,"line":…,"confidence":…}
  │
  └─ <Enter> → edit <file>  +  jump to line  +  zz
```

Claude Code runs with its full tool suite, so it can:
- `grep_ast` the project for template specialisations
- `read_file` headers it finds via `#include` traces
- Reason about SFINAE / concept constraints

## Call-stack view (`gC`)

```
  caller_A()  [gemm.h:120]
  └── caller_B()  [mma.h:44]
      └── MmaAtomShape()  [current]
              ├── Layout::stride()   [layout.h:88]
              └── TensorRef::data()  [tensor_ref.h:102]
```

Nodes Claude cannot confirm are marked `[?]`.

## Tips

- Open Neovim from the project root so Claude can resolve relative paths.
- For very large projects increase `context_lines` to 100 for more signal.
- Set `auto_jump = true` if you trust Claude's high-confidence hits.
