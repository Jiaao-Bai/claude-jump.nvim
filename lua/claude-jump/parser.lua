-- Parse Claude's response to extract structured navigation data.
local M = {}

local SENTINEL = "---JUMP-RESULT---"
local VALID_CONFIDENCE = { high = true, medium = true, low = true }

--- Strict validation of a decoded JSON table.
--- Returns a clean result table or nil.
local function validate(data)
  if type(data) ~= "table" then return nil end

  local file = data.file
  if file == vim.NIL then file = nil end
  if file ~= nil and type(file) ~= "string" then return nil end
  if file == "null" or file == "" then file = nil end

  local line = data.line
  if line == vim.NIL then line = nil end
  line = tonumber(line)
  if line and (line < 1 or line ~= math.floor(line)) then line = nil end

  -- A null file means Claude couldn't find it — that's valid, just return nil
  if not file then return nil end

  local confidence = data.confidence
  if not VALID_CONFIDENCE[confidence] then confidence = "low" end

  return {
    file        = file,
    line        = line or 1,
    confidence  = confidence,
    explanation = type(data.explanation) == "string" and data.explanation or "",
  }
end

--- Extract JSON that follows the sentinel marker.
local function from_sentinel(text)
  -- Match everything after "---JUMP-RESULT---\n"
  local after = text:match(SENTINEL .. "\n(.*)")
  if not after then return nil end

  -- Strip optional ```json fence
  local inner = after:match("^```[jJ][sS][oO][nN]?%s*\n?(.-)\n?```") or after
  local ok, decoded = pcall(vim.fn.json_decode, vim.trim(inner))
  if ok then return validate(decoded) end
  return nil
end

--- Last-resort: scan for file:line patterns in free-form text.
local function pattern_extract(text)
  local file, line = text:match("([%.%/]?[%w%./%-_]+%.%a+):(%d+)")
  if file and line then
    return { file = file, line = tonumber(line), confidence = "low", explanation = "pattern match fallback" }
  end
  file, line = text:match("([%.%/]?[%w%./%-_]+%.%a+)[,]?%s+line%s+(%d+)")
  if file and line then
    return { file = file, line = tonumber(line), confidence = "low", explanation = "pattern match fallback" }
  end
  return nil
end

--- Parse a jump-to-definition response.
--- Returns { file, line, confidence, explanation } or nil.
function M.definition(response)
  -- Primary: sentinel-delimited JSON (what the prompt asks for)
  local r = from_sentinel(response)
  if r then return r end

  -- Fallback: last-resort pattern match (e.g., if Claude ignored the sentinel)
  return pattern_extract(response)
end

--- Expose the sentinel so the prompt builder can embed it.
M.SENTINEL = SENTINEL

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
