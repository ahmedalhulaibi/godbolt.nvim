local M = {}
local running = {}

local function fail(message)
  vim.notify('[Godbolt] ' .. message, vim.log.levels.ERROR)
end

function M.compile(output_type)
  if output_type ~= 'asm' and output_type ~= 'llvm' then
    fail('Output must be asm or llvm')
    return
  end
  local godbolt = require('godbolt')
  local source = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(source)
  if not file:match('%.zig$') or vim.bo[source].buftype ~= '' then
    fail('Open a saved Zig source file first')
    return
  end
  if running[source] then
    fail('A build is already running for this buffer')
    return
  end
  if vim.bo[source].modified then
    local ok, err = pcall(vim.cmd, 'write')
    if not ok then fail(tostring(err)); return end
  end
  local source_line = vim.api.nvim_win_get_cursor(0)[1]
  local build_file = vim.fs.find('build.zig', { path = vim.fs.dirname(file), upward = true, type = 'file' })[1]
  if not build_file then
    local args = output_type == 'llvm' and '-femit-llvm-ir' or '-femit-asm'
    local output = godbolt.godbolt(args, { output = output_type })
    vim.schedule(function()
      if output and vim.api.nvim_buf_is_valid(output) then
        require('godbolt.line_map').focus_source_line(source_line)
      end
    end)
    return output
  end

  local root = vim.fs.dirname(build_file)
  local prefix = vim.fn.tempname()
  local step = output_type == 'llvm' and 'godbolt-ir' or 'godbolt-asm'
  local artifact = prefix .. '/godbolt/output.' .. (output_type == 'llvm' and 'll' or 's')
  local cmd = { godbolt.config.zig, 'build', step }
  vim.list_extend(cmd, vim.b[source].godbolt_build_args or godbolt.config.zig_build_args)
  vim.list_extend(cmd, { '--prefix', prefix })
  local command = table.concat(vim.tbl_map(vim.fn.shellescape, cmd), ' ')
  vim.g.last_godbolt_cmd = command
  running[source] = true
  local changedtick = vim.api.nvim_buf_get_changedtick(source)
  vim.notify('[Godbolt] Building ' .. step, vim.log.levels.INFO)

  local ok, err = pcall(vim.system, cmd, { cwd = root, text = true }, function(result)
    vim.schedule(function()
      running[source] = nil
      local lines = nil
      local read_error = nil
      if result.code == 0 and vim.fn.filereadable(artifact) == 1 then
        local read_ok, value = pcall(require('godbolt.zig_output').read, artifact, output_type, file)
        if read_ok then lines = value else read_error = tostring(value) end
      end
      vim.fn.delete(prefix, 'rf')
      if result.code ~= 0 then
        fail('Project build failed; no standalone fallback. Add the ' .. step ..
          ' step to build.zig if missing.\n' .. (result.stderr or '') .. (result.stdout or ''))
        return
      end
      if not lines then
        fail(read_error or 'No emitted code for this file. Check the build output, reachable functions, and optimization level.')
        return
      end
      if not vim.api.nvim_buf_is_valid(source) or vim.api.nvim_buf_get_name(source) ~= file then return end
      if vim.api.nvim_buf_get_changedtick(source) ~= changedtick then
        fail('Source changed during compilation; run the keymap again')
        return
      end
      godbolt.show_output(lines, source, output_type, command, source_line)
    end)
  end)
  if not ok then
    running[source] = nil
    vim.fn.delete(prefix, 'rf')
    fail(tostring(err))
  end
end

return M
