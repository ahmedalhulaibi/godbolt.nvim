local M = {}

local function assembly(path, source_file)
  local declarations, selected_ids = {}, {}
  for line in io.lines(path) do
    local id, directory, name = line:match('^%s*%.file%s+(%d+)%s+"([^"]*)"%s+"([^"]+)"')
    if not id then id, name = line:match('^%s*%.file%s+(%d+)%s+"([^"]+)"') end
    if id then
      local file = name:sub(1, 1) == '/' and name or (directory and directory .. '/' .. name or name)
      if vim.fn.fnamemodify(file, ':p') == source_file then
        selected_ids[id] = true
        declarations[#declarations + 1] = line
      end
    elseif line:match('^%s*%.intel_syntax') then
      declarations[#declarations + 1] = line
    end
  end
  local selected, found = false, false
  for line in io.lines(path) do
    local id, source_line = line:match('^%s*%.loc%s+(%d+)%s+(%d+)')
    if id then
      selected = selected_ids[id] == true and tonumber(source_line) > 0
    elseif line:match('^%s*%.cfi_endproc') or line:match('^%s*%.size%s') or
        line:match('^%s*%.section%s') then
      selected = false
    end
    if selected then declarations[#declarations + 1] = line; found = true end
  end
  return found and declarations or nil
end

local function llvm(path, source_file)
  local metadata_lines = {}
  for line in io.lines(path) do
    local kind = line:match('^!%d+%s*=%s*.-!(%w+)%(')
    if kind == 'DIFile' or kind == 'DISubprogram' or kind == 'DILexicalBlock' or
        kind == 'DILexicalBlockFile' or kind == 'DILocation' or kind == 'DILocalVariable' then
      metadata_lines[#metadata_lines + 1] = line
    end
  end
  local _, _, locations = require('godbolt.parsers.llvm_ir').parse(metadata_lines, source_file)
  local output, func, selected, found = {}, nil, false, false
  local needed, attributes, needed_attributes = {}, {}, {}
  for line in io.lines(path) do
    if line:match('^define%s') then func = {}; selected = false end
    if func then
      func[#func + 1] = line
      local location = line:match('!dbg%s+!(%d+)')
      if line:match('^%s*#dbg_') then
        for ref in line:gmatch('!(%d+)') do location = ref end
      end
      if location and locations[tonumber(location)] then selected = true end
      if line:match('^}') then
        if selected then
          vim.list_extend(output, func)
          found = true
          for _, instruction in ipairs(func) do
            for ref in instruction:gmatch('!(%d+)') do needed[ref] = true end
            for attribute in instruction:gmatch('#(%d+)') do needed_attributes[attribute] = true end
          end
        end
        func = nil
      end
    elseif line:match('^source_filename') or line:match('^target%s') then
      output[#output + 1] = line
    elseif line:match('^attributes%s') then
      attributes[line:match('#(%d+)')] = line
    end
  end
  if not found then return nil end
  local nodes = {}
  for _, line in ipairs(metadata_lines) do nodes[line:match('^!(%d+)')] = line end
  local visited = {}
  local function retain(id)
    if visited[id] then return end
    visited[id] = true
    local node = nodes[id]
    if not node or (node:match('!DILocation%(') and not locations[tonumber(id)]) then return end
    needed[id] = true
    for ref in node:gmatch('!(%d+)') do retain(ref) end
  end
  for id in pairs(needed) do retain(id) end
  for _, line in ipairs(metadata_lines) do
    local id = line:match('^!(%d+)')
    if needed[id] and (not line:match('!DILocation%(') or locations[tonumber(id)]) then
      output[#output + 1] = line
    end
  end
  local attribute_ids = vim.tbl_keys(needed_attributes)
  table.sort(attribute_ids, function(a, b) return tonumber(a) < tonumber(b) end)
  for _, id in ipairs(attribute_ids) do
    if attributes[id] then output[#output + 1] = attributes[id] end
  end
  return output
end

function M.read(path, output_type, source_file)
  source_file = vim.fn.fnamemodify(source_file, ':p')
  return (output_type == 'llvm' and llvm or assembly)(path, source_file)
end

return M
