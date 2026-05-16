-- Async Claude CLI runner.
local M = {}

--- Start a non-interactive Claude session and stream the output.
---
--- @param prompt   string   Full prompt text (sent via stdin).
--- @param config   table    Plugin config (claude_cmd, claude_flags).
--- @param on_line  function Called in the Neovim main loop for each non-empty line.
--- @param on_done  function Called with (exit_code, full_output, stderr_output).
--- @return number|nil  job_id (pass to M.stop() to cancel early)
function M.run(prompt, config, on_line, on_done)
  local cmd = vim.list_extend({ config.claude_cmd or "claude" }, config.claude_flags or { "--print" })

  local stdout_acc = {}
  local stderr_acc = {}

  local job_id = vim.fn.jobstart(cmd, {
    stdin = "pipe",

    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stdout_acc, line)
          vim.schedule(function() on_line(line) end)
        end
      end
    end,

    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stderr_acc, line)
        end
      end
    end,

    on_exit = function(_, code)
      vim.schedule(function()
        on_done(code, table.concat(stdout_acc, "\n"), table.concat(stderr_acc, "\n"))
      end)
    end,
  })

  if not job_id or job_id <= 0 then
    vim.notify("claude-jump: failed to start '" .. cmd[1] .. "' — is Claude CLI installed?", vim.log.levels.ERROR)
    return nil
  end

  vim.fn.chansend(job_id, prompt)
  vim.fn.chanclose(job_id, "stdin")

  return job_id
end

function M.stop(job_id)
  if job_id and job_id > 0 then
    pcall(vim.fn.jobstop, job_id)
  end
end

return M
