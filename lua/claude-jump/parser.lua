-- Parse Claude's response to extract structured navigation data.
local M = {}

--- Find the last JSON object in `text` that has a "file" key.
--- Returns decoded table or nil.
local function last_json_with_file(text)
  local result = nil

  -- Collect all {...} spans (not nested-aware but handles typical responses)
  for block in text:gmatch("%b{}") do
    local ok, decoded = pcall(vim.fn.json_decode, block)
    if ok and type(decoded) == "table" and (decoded.file ~= nil or decoded.path ~= nil) then
      result = decoded
    end
  end

  -- Also try fenced ```json ... ``` blocks
  for block in text:gmatch("```[jJ][sS][oO][nN]%s*(.-)%s*```") do
    local ok, decoded = pcall(vim.fn.json_decode, block)
    if ok and type(decoded) == "table" and (decoded.file ~= nil or decoded.path ~= nil) then
      result = decoded
    end
  end

  return result
end

--- Fallback: scan for file:line patterns in free-form text.
local function pattern_extract(text)
  -- /abs/path/file.ext:123  or  relative/file.ext:123
  local file, line = text:match("([%.%/]?[%w%./%-_]+%.%a+):(%d+)")
  if file and line then
    return { file = file, line = tonumber(line), confidence = "low", explanation = "pattern match fallback" }
  end
  -- "file.ext, line 123" or "file.ext line 123"
  file, line = text:match("([%.%/]?[%w%./%-_]+%.%a+)[,]?%s+line%s+(%d+)")
  if file and line then
    return { file = file, line = tonumber(line), confidence = "low", explanation = "pattern match fallback" }
  end
  return nil
end

--- Parse a jump-to-definition response.
--- Returns { file, line, confidence, explanation } or nil.
function M.definition(response)
  local data = last_json_with_file(response)
  if data then
    local file = data.file or data.path
    if file == vim.NIL or file == "null" then file = nil end
    local line = tonumber(data.line or data.line_number)
    if not file then return nil end
    return {
      file        = file,
      line        = line or 1,
      confidence  = data.confidence or "medium",
      explanation = data.explanation or data.reason or "",
    }
  end
  return pattern_extract(response)
end

--- Resolve a path that might be relative.
--- Returns the best readable filepath, or nil.
function M.resolve_path(raw_path, source_filepath)
  if vim.fn.filereadable(raw_path) == 1 then return raw_path end

  -- Relative to cwd
  local cwd_rel = vim.fn.getcwd() .. "/" .. raw_path
  if vim.fn.filereadable(cwd_rel) == 1 then return cwd_rel end

  -- Relative to the source file's directory
  if source_filepath and source_filepath ~= "" then
    local dir = vim.fn.fnamemodify(source_filepath, ":h")
    local dir_rel = dir .. "/" .. raw_path
    if vim.fn.filereadable(dir_rel) == 1 then return dir_rel end
  end

  return nil
end

return M
