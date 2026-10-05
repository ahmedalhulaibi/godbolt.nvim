local M = {}

function M.compile(output_type, opts)
  if not opts then return require('godbolt.panes').open(output_type) end
  local godbolt = require('godbolt')
  local source = opts.source
  local file = vim.api.nvim_buf_get_name(source)
  local changedtick = vim.api.nvim_buf_get_changedtick(source)
  local function current()
    return vim.api.nvim_buf_is_valid(source) and vim.api.nvim_buf_get_name(source) == file and
      vim.api.nvim_buf_get_changedtick(source) == changedtick and opts.current()
  end
  local build_file = vim.fs.find('build.zig', { path = vim.fs.dirname(file), upward = true, type = 'file' })[1]
  if not build_file then
    local ok, result = pcall(vim.api.nvim_buf_call, source, function()
      local args = output_type == 'llvm' and '-femit-llvm-ir' or '-femit-asm'
      return godbolt.godbolt(args, { output = output_type, capture = true })
    end)
    opts.done(not current() and { cancelled = true } or (ok and result or { error = tostring(result) }))
    return
  end

  local prefix = vim.fn.tempname()
  local step = output_type == 'llvm' and 'godbolt-ir' or 'godbolt-asm'
  local artifact = prefix .. '/godbolt/output.' .. (output_type == 'llvm' and 'll' or 's')
  local cmd = { godbolt.config.zig, 'build', step }
  vim.list_extend(cmd, vim.b[source].godbolt_build_args or godbolt.config.zig_build_args)
  vim.list_extend(cmd, { '--prefix', prefix })
  local command = table.concat(vim.tbl_map(vim.fn.shellescape, cmd), ' ')
  vim.g.last_godbolt_cmd = command
  vim.notify('[Godbolt] Building ' .. step, vim.log.levels.INFO)
  local ok, err = pcall(vim.system, cmd, { cwd = vim.fs.dirname(build_file), text = true }, function(result)
    vim.schedule(function()
      local data = { command = command }
      if not current() then
        data.cancelled = true
      elseif result.code ~= 0 then
        data.error = 'Project build failed; no standalone fallback. Add the ' .. step ..
          ' step to build.zig if missing.\n' .. (result.stderr or '') .. (result.stdout or '')
      elseif vim.fn.filereadable(artifact) ~= 1 then
        data.error = 'Build did not emit godbolt/output.' .. (output_type == 'llvm' and 'll' or 's')
      else
        local read_ok, value = pcall(require('godbolt.zig_output').read, artifact, output_type, file)
        if read_ok then
          data.lines = value
          if not value then data.error = 'No emitted code for this file; it may be unused or optimized away.' end
        else
          data.error = tostring(value)
        end
      end
      vim.fn.delete(prefix, 'rf')
      opts.done(data)
    end)
  end)
  if not ok then
    vim.fn.delete(prefix, 'rf')
    opts.done({ error = tostring(err), command = command })
  end
end

return M
