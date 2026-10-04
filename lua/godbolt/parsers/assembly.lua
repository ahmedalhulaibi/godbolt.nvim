local M = {}

-- Check if a line is an actual instruction (not directive, label, or comment)
local function is_instruction(line)
  -- Must start with whitespace (indented)
  if not line:match("^%s+") then
    return false
  end

  -- Skip directives (start with .)
  if line:match("^%s*%.") then
    return false
  end

  -- Skip labels (end with :)
  if line:match("^[%w_]+:") then
    return false
  end

  -- Skip comments
  if line:match("^%s*;") or line:match("^%s*//") or line:match("^%s*#") then
    return false
  end

  -- Must have an instruction mnemonic
  if line:match("^%s+[a-z][%w.]*%s") or line:match("^%s+[a-z][%w.]*$") then
    return true
  end

  return false
end

-- Parse assembly output and build line mappings
-- Returns: src_to_asm, asm_to_src tables
function M.parse(asm_lines, source_file)
  local src_to_asm = {} -- source_line → [asm_line_nums]
  local asm_to_src = {} -- asm_line_num → source_line
  local file_table = {} -- file_id → file_path
  local current_src_line = nil
  local source_file_id = 0
  if source_file then source_file_id = nil end

  for _, line in ipairs(asm_lines) do
    local id, directory, name = line:match('%.file%s+(%d+)%s+"([^"]*)"%s+"([^"]+)"')
    if not id then
      id, name = line:match('%.file%s+(%d+)%s+"([^"]+)"')
    end
    if id then
      local path = directory and (directory .. "/" .. name) or name
      file_table[tonumber(id)] = name
      if source_file and vim.fn.fnamemodify(path, ":p") == vim.fn.fnamemodify(source_file, ":p") then
        source_file_id = tonumber(id)
      end
    end
  end

  for asm_line_num, line in ipairs(asm_lines) do
    -- Parse .loc directive
    -- Format: .loc file_id line column [flags]
    -- Example: .loc 0 2 18 prologue_end
    local loc_file, loc_line, loc_col = line:match("%.loc%s+(%d+)%s+(%d+)%s+(%d+)")

    if loc_file and loc_line then
      local file_id_num = tonumber(loc_file)
      local src_line = tonumber(loc_line)

      if file_id_num == source_file_id and src_line > 0 then
        current_src_line = src_line
        -- Also record the .loc line itself in reverse mapping
        asm_to_src[asm_line_num] = current_src_line
      else
        current_src_line = nil
      end
    end

    -- Map actual instructions to current source line
    if current_src_line and is_instruction(line) then
      -- Forward mapping: add this asm line to source line's list
      if not src_to_asm[current_src_line] then
        src_to_asm[current_src_line] = {}
      end
      table.insert(src_to_asm[current_src_line], asm_line_num)

      -- Reverse mapping
      asm_to_src[asm_line_num] = current_src_line
    end
  end

  return src_to_asm, asm_to_src, file_table
end

return M
