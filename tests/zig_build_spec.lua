local godbolt = require('godbolt')

describe('Zig build-aware compilation', function()
  local cases = {
    { name = 'standalone assembly fallback', format = 'asm' },
    { name = 'standalone IR fallback', format = 'llvm' },
    { name = 'project assembly', project = 'zig_project', format = 'asm', file = 'main.zig', line = 4 },
    { name = 'project IR', project = 'zig_project', format = 'llvm', file = 'main.zig', line = 4 },
    { name = 'dependency source assembly', project = 'zig_project', format = 'asm', file = 'helper.zig' },
    { name = 'dependency source IR', project = 'zig_project', format = 'llvm', file = 'helper.zig' },
    { name = 'failed project never falls back', project = 'zig_project_failure', format = 'llvm', failure = true },
    { name = 'missing artifact never shows stale output', project = 'zig_project_failure', format = 'asm', failure = true },
  }
  for _, case in ipairs(cases) do
    it(case.name, function()
      local original = vim.deepcopy(godbolt.config)
      local notify = vim.notify
      local levels = {}
      local dir = vim.fn.tempname() .. " space'quote"
      local source, output
      vim.fn.mkdir(dir .. '/src', 'p')
      if case.project then
        vim.fn.writefile(vim.fn.readfile('testdata/inputs/' .. case.project .. '/build.zig'), dir .. '/build.zig')
        if case.project == 'zig_project' then
          for _, file in ipairs({ 'main.zig', 'helper.zig' }) do
            vim.fn.writefile(vim.fn.readfile('testdata/inputs/zig_project/src/' .. file), dir .. '/src/' .. file)
          end
        end
      end
      local file = dir .. '/src/' .. (case.file or 'standalone.zig')
      if not case.file then vim.fn.writefile(vim.fn.readfile('testdata/inputs/add.zig'), file) end
      local ok, err = pcall(function()
        vim.notify = function(_, level) levels[#levels + 1] = level end
        godbolt.setup({
          zig = vim.env.GODBOLT_TEST_ZIG or 'zig',
          zig_args = '-O ReleaseFast', zig_build_args = { '-Doptimize=ReleaseFast' },
          line_mapping = { enabled = true, auto_scroll = false },
        })
        vim.cmd('edit ' .. vim.fn.fnameescape(file))
        source = vim.api.nvim_get_current_buf()
        local line = case.line or 2
        vim.api.nvim_win_set_cursor(0, { line, 0 })
        vim.api.nvim_buf_set_lines(source, 0, 0, false, { '' })
        vim.api.nvim_win_set_cursor(0, { line + 1, 0 })
        godbolt.godbolt_zig(case.format)
        assert.is_false(vim.bo[source].modified, 'Keymap must save modified source')
        assert.are.equal('', vim.fn.readfile(file)[1])
        assert.is_true(vim.wait(60000, function()
          local current = vim.api.nvim_get_current_buf()
          if current ~= source then output = current; return true end
          return levels[#levels] == vim.log.levels.ERROR
        end, 20), 'Build must finish')
        if case.failure then
          assert.are.equal(source, vim.api.nvim_get_current_buf(), 'Do not open fallback or stale output')
          assert.are.same({ vim.log.levels.INFO, vim.log.levels.ERROR }, levels)
          return
        end
        assert.are.equal(case.format, vim.bo[output].filetype)
        assert.are.same(vim.fn.readfile(file), vim.api.nvim_buf_get_lines(source, 0, -1, false))
        local forward = require('godbolt.parsers.' .. (case.format == 'llvm' and 'llvm_ir' or 'assembly')).parse(
          vim.b[output].godbolt_full_output, file)
        assert.is_true(#(forward[line + 1] or {}) > 0, 'Selected file must have mapped instructions')
        vim.wait(100, function() return false end)
        local displayed = vim.api.nvim_win_get_cursor(0)[1]
        local original_line = (vim.b[output].godbolt_line_map or {})[displayed] or displayed
        assert.are.equal(forward[line + 1][1], original_line, 'Output cursor must focus the source expression')
        if case.project then
          assert.are.same({ vim.log.levels.INFO }, levels)
          local lines = vim.b[output].godbolt_full_output
          if case.format == 'asm' then
            local _, _, files = require('godbolt.parsers.assembly').parse(lines, file)
            for _, instruction in ipairs(lines) do
              local id = instruction:match('^%s*%.loc%s+(%d+)')
              if id then assert.are.equal(case.file, files[tonumber(id)], 'Exclude other files from assembly view') end
            end
          else
            local names = {}
            for _, instruction in ipairs(lines) do
              local name = instruction:match('^define%s+.-@([%w_.]+)%(')
              if name then names[#names + 1] = name end
            end
            local expected = case.file == 'helper.zig' and { 'helper.increment' } or { 'main.calculate' }
            assert.are.same(expected, names, vim.inspect(names))
          end
          local cmd = vim.g.last_godbolt_cmd
          local prefix = cmd:match("'--prefix' '([^']+)'$")
          assert.is_not_nil(prefix)
          assert.are.equal(0, vim.fn.isdirectory(prefix), 'Temporary install prefix must be deleted')
        end
      end)
      require('godbolt.panes').close()
      require('godbolt.line_map').cleanup()
      vim.notify = notify
      godbolt.config = original
      if output then pcall(vim.api.nvim_buf_delete, output, { force = true }) end
      if source then pcall(vim.api.nvim_buf_delete, source, { force = true }) end
      vim.fn.delete(dir, 'rf')
      assert.is_true(ok, tostring(err))
    end)
  end
end)
