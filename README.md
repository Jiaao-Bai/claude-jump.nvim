# claude-jump.nvim

AI-powered go-to-definition for Neovim, powered by Claude Code.
For when ctags and clangd give up — think CUTLASS-level C++ template metaprogramming.

*Neovim 里基于 Claude Code 的语义跳转插件。当 ctags 和 clangd 都搞不定的时候用 —— 比如 CUTLASS 那种深度模板元编程的代码。*

---

## 1. Design Philosophy

### The plugin enforces the I/O contract. Claude does everything else.

This is the one rule everything else falls out of. Claude Code has real semantic
understanding and a full tool suite (`grep`, `read_file`, `list_directory`, …).
Treating it like a function that needs careful parameter tuning would defeat the
point. So we hand Claude as much latitude as possible and only enforce what we
strictly need to make Neovim aware of jumpable locations.

*整个插件只守一条规矩：约定好和 Claude 之间的 I/O 协议，剩下所有判断（搜什么、读哪些文件、调用栈展开多深、什么是信号什么是噪音）全部交给 Claude。Claude Code 本身就有完整工具链和语义理解能力，把它当成需要精细调参的函数反而扼杀了它的价值。*

### The contract has exactly three invariants

1. **`[path:line]` is the universal jumpable-location marker.** Anywhere Claude
   writes one in its output, the user can press `<CR>` on that line in the
   floating window to navigate there.
2. **`:ClaudeJump` ends with a sentinel + JSON.** Claude writes
   `---JUMP-RESULT---` on its own line, then one JSON object. This is the
   canonical answer the plugin uses for `auto_jump`.
3. **One Claude job at a time.** While Claude is running, new `gc` / `gC`
   presses are silently ignored (with a status message) rather than killing
   the running job. Single-threaded mental model.

*协议层面只有三条硬约束：(1) `[path:line]` 是唯一的"可跳转位置"标记，Claude 输出里任何这样的标记都能按 `<CR>` 跳过去；(2) `:ClaudeJump` 用 `---JUMP-RESULT---` 哨兵后跟一个 JSON 作为正式答案，供 auto_jump 使用；(3) 后台只有一个 Claude 单线程在跑，运行中按新的快捷键会被静默忽略，不会 cancel-and-restart。*

### What this means in practice

- No `caller_depth`, no `max_siblings`, no per-language switches. The prompt
  *guides* Claude with soft hints ("output renders in a ~30-line window, prefer
  signal over completeness") and Claude makes the calls.
- Claude's intermediate reasoning isn't just for show — every `[path:line]` it
  emits while exploring becomes a usable jump target. The process is also the
  product.
- The floating buffer is named `claude://output` and is persistent: closing
  the window hides it, it doesn't destroy the content. After jumping you can
  `:ClaudeFocus` to come right back and see what Claude said.

*具体表现：(1) 没有 caller_depth / max_siblings / per-language 这些配置开关，prompt 只给 Claude 软引导，由 Claude 自己拿主意；(2) Claude 推理过程中提到的每个 `[path:line]` 都是可跳转的——过程本身也是产物；(3) 浮动 buffer 叫 `claude://output`，是常驻的——关窗口只是隐藏，跳走以后 `:ClaudeFocus` 随时能回来看 Claude 之前的输出。*

---

## 2. Code Architecture

### Module layout

```
lua/claude-jump/
├── config.lua    Defaults + setup() merge
├── context.lua   Cursor context capture (symbol, file, ±N lines)
├── claude.lua    Async Claude CLI runner (jobstart + stdin pipe)
├── parser.lua    Sentinel-delimited JSON parser + [path:line] extractor
├── ui.lua        Persistent buffer + floating-window lifecycle
└── init.lua      Orchestrator: prompts, M.jump / M.call_stack / M.focus

plugin/claude-jump.lua    User commands (:ClaudeJump / :ClaudeCallStack / :ClaudeFocus)
```

*模块划分：`config` 默认配置、`context` 抓取光标上下文、`claude` 异步调 CLI、`parser` 解析输出、`ui` 管理常驻 buffer 和浮窗、`init` 总调度。*

### Data flow for a single `gc`

```
user presses gc
   │
   │ [busy() check]  if a Claude job is already running → notify + return
   │
   ├─ context.get()       symbol, filepath, row, col, ±5 lines of code
   │
   ├─ fmt_jump_prompt()   embed context + sentinel + [path:line] convention
   │
   ├─ ui.open()           reuse the claude://output buffer, clear it, float
   │                      (bufhidden=hide, syntax-highlight [path:line])
   │
   ├─ bind_window_keys()  <CR> on current line → location_on_line() → jump
   │
   ├─ claude.run()        jobstart({"claude", "--print"}, stdin=pipe)
   │   │
   │   ├─ on_stdout       schedule(ui.append) — stream output live
   │   ├─ on_stderr       buffered for error reporting
   │   └─ on_exit         schedule(on_done) — parser.definition(full_output)
   │                      → result {file, line, confidence, explanation}
   │                      → park cursor on result line
   │                      → auto-jump if confidence == "high" and configured
   │
   └─ <CR>                close float, edit resolved file, set cursor, zz
```

*单次 `gc` 的数据流：先 `busy()` 检查后台是否已经有 Claude 在跑；然后抓上下文 → 构造 prompt → 复用常驻 buffer 开浮窗 → 异步启动 claude --print，流式把输出写进浮窗 → Claude 退出后解析哨兵后的 JSON → 光标停在结果行 → 用户按 `<CR>` 跳转。*

### Key design choices

| Choice | Why |
|---|---|
| **stdin pipe** for prompt | No shell injection, no arg-length limits |
| **Persistent buffer** `claude://output` | Single dedicated buffer, survives window close, enables `:ClaudeFocus` |
| **Sentinel `---JUMP-RESULT---`** before final JSON | Robust parsing: Claude's tool-call JSON earlier in the stream is ignored |
| **Strict type validation** in parser | `file: string\|nil`, `line: positive integer`, `confidence ∈ {high,medium,low}` |
| **Ignore-while-busy** instead of cancel | Misclicks don't trash an in-flight job; single-worker mental model |
| **`<CR>` parses current line, not preselected** | One uniform interaction for jump-result line, call-tree nodes, reasoning mentions |

*关键决策对照：用 stdin 管道传 prompt（防注入 + 长度无限制）；常驻 buffer 允许跳回查看；哨兵分隔确保 JSON 解析鲁棒；严格类型校验拦住 Claude 偶尔的格式漂移；忽略而非取消保证手误安全；统一的 `<CR>` 行内解析消除了不同窗口的交互差异。*

---

## 3. Configuration & Keymaps

### Full defaults

```lua
require("claude-jump").setup({
  -- Claude CLI invocation
  claude_cmd    = "claude",         -- binary on $PATH
  claude_flags  = { "--print" },    -- non-interactive mode

  -- Input size (lines of code around the cursor sent to Claude)
  -- Small on purpose: Claude reads files itself via tools.
  context_lines = 5,

  -- Floating window
  ui = {
    width  = 0.58,                  -- fraction of editor columns
    height = 0.68,                  -- fraction of editor lines
    border = "rounded",             -- see :h nvim_open_win
  },

  -- Auto-jump when Claude reports confidence == "high"
  auto_jump = false,

  -- Keymaps (set any value to false / nil to disable)
  keymaps = {
    jump       = "gc",              -- :ClaudeJump      go to definition
    call_stack = "gC",              -- :ClaudeCallStack show call hierarchy
    focus      = nil,               -- :ClaudeFocus     re-open Claude buffer
  },
})
```

*完整默认配置如上。所有 keymap 值设成 `false` 或 `nil` 就禁用对应的全局快捷键。*

### Global keymaps

These are the editor-wide bindings registered by `setup()`:

| Default | Config key       | Command            | Action                                                |
|---------|------------------|--------------------|-------------------------------------------------------|
| `gc`    | `keymaps.jump`        | `:ClaudeJump`      | Find & jump to definition of symbol under cursor      |
| `gC`    | `keymaps.call_stack`  | `:ClaudeCallStack` | Render call hierarchy (callers + callees) as a tree   |
| *(none)* | `keymaps.focus`      | `:ClaudeFocus`     | Re-open the Claude output buffer (e.g. after jumping) |

*插件在全局注册的三个快捷键。`focus` 默认不绑定——常见值是 `g.` 或 `g<CR>`。三个用户命令始终可用。*

### Inside the floating window

When the Claude output float is focused, these bindings are active (set
internally, not configurable — they're part of the I/O contract):

| Key       | Action                                                                                                  |
|-----------|---------------------------------------------------------------------------------------------------------|
| `<CR>`    | Scan the current line for `[path:line]`; if found, close the float and jump there                       |
| `q`       | Hide the floating window (the buffer is kept — re-open later with `:ClaudeFocus`)                       |
| `<Esc>`   | Same as `q`                                                                                             |

*浮窗里的内置按键。`<CR>` 是"扫当前行的 `[path:line]` 标记并跳过去"，对所有窗口（jump 结果行、调用栈树节点、Claude 推理中提到的位置）统一生效。`q` / `<Esc>` 只是隐藏窗口，buffer 保留，之后用 `:ClaudeFocus` 能调回来。*

### Suggested user setup

```lua
require("claude-jump").setup({
  auto_jump = true,                 -- skip the Enter confirmation on high-confidence hits
  keymaps = {
    jump       = "gc",
    call_stack = "gC",
    focus      = "g.",              -- mnemonic: "go to the . (last Claude thing)"
  },
})
```

*推荐配置：信任高置信结果时打开 `auto_jump`，并给 `focus` 绑一个顺手的键（`g.` 比较好记——"回到上一次 Claude 输出的地方"）。*

---

## Requirements & Installation

- Neovim 0.9+
- [Claude Code CLI](https://docs.anthropic.com/claude-code) on `$PATH`. Auth is handled by Claude Code itself — no API keys to manage.

```lua
-- lazy.nvim
{
  "jiaao-bai/claude-jump.nvim",
  config = function() require("claude-jump").setup() end,
}
```

*要求 Neovim 0.9+ 和已安装好的 Claude Code CLI。不需要单独配 API key。*

## Positioning

This is a **fallback** tool. Your LSP is faster, more accurate, and uses no
inference budget for the 95% of jumps it can handle. Reach for `gc` when
clangd shrugs at a templated specialisation buried five `#include`s deep.

*定位：这是 LSP 的**兜底**工具，不是日常导航。95% 的跳转交给你的 LSP，更快更准也不烧 token。等到 clangd 在深度模板特化前面摆手的时候，再用 `gc`。*
