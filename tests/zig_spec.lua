local godbolt = require('godbolt')

describe('Zig compilation', function()
  local cases = {
    { name = 'assembly command', args = '-O ReleaseFast', command = true, filetype = 'asm', line = 2 },
    { name = 'LLVM flag', args = '-O ReleaseFast -femit-llvm-ir', filetype = 'llvm', line = 2 },
    { name = 'LLVM preference', args = '-O ReleaseSafe', opts = { output = 'llvm' }, filetype = 'llvm', line = 2 },
    { name = 'first-line flags', fixture = 'comment.zig', args = '', filetype = 'llvm', line = 3 },
    { name = 'configured defaults', args = '', defaults = '-O ReleaseFast', filetype = 'asm', line = 2 },
    { name = 'debug assembly', args = '', filetype = 'asm', line = 2 },
  }

  for _, case in ipairs(cases) do
    it(case.name, function()
      assert.are.equal(1, vim.fn.executable('zig'), 'Zig with LLVM support is required')
      local original = vim.deepcopy(godbolt.config)
      local dir = vim.fn.tempname() .. " space'quote"
      vim.fn.mkdir(dir, 'p')
      local file = dir .. '/example.zig'
      vim.fn.writefile(vim.fn.readfile('testdata/inputs/' .. (case.fixture or 'add.zig')), file)
      local source, output
      local ok, err = pcall(function()
        godbolt.setup({ zig_args = case.defaults or '', line_mapping = { enabled = true, auto_scroll = false } })
        vim.cmd('edit ' .. vim.fn.fnameescape(file))
        source = vim.api.nvim_get_current_buf()
        if case.command then
          vim.cmd('runtime plugin/godbolt.lua')
          vim.cmd('Godbolt ' .. case.args)
        else
          godbolt.godbolt(case.args, case.opts)
        end
        output = vim.api.nvim_get_current_buf()
        assert.are.equal(case.filetype, vim.bo[output].filetype)
        local lines = vim.b[output].godbolt_full_output
        local parser = require('godbolt.parsers.' .. (case.filetype == 'llvm' and 'llvm_ir' or 'assembly'))
        local forward, reverse = parser.parse(lines, file)
        assert.is_not_nil(forward[case.line], 'Return expression must map to output')
        assert.is_true(#forward[case.line] > 0)
        for _, output_line in ipairs(forward[case.line]) do
          local mapped = reverse[output_line]
          assert.are.equal(case.line, type(mapped) == 'table' and mapped.line or mapped)
        end
        vim.wait(50, function() return false end)
        local highlights = require('godbolt.highlight')
        local highlighted = highlights.get_highlighted_lines(source, highlights.ns_static)
        assert.is_true(#highlighted > 0, 'Scheduled source mapping must install highlights')
        local path = vim.g.last_godbolt_cmd:match("%-femit%-[%w%-]+=([^\n]+)$")
        assert.is_not_nil(path)
        path = path:gsub("^'", ''):gsub("'$", '')
        assert.are.equal(0, vim.fn.filereadable(path), 'Temporary output must be deleted')
        assert.are.same({ file }, vim.fn.glob(dir .. '/*', false, true), 'No object or output files beside source')
      end)
      require('godbolt.line_map').cleanup()
      godbolt.config = original
      if output then pcall(vim.api.nvim_buf_delete, output, { force = true }) end
      if source then pcall(vim.api.nvim_buf_delete, source, { force = true }) end
      vim.fn.delete(dir, 'rf')
      assert.is_true(ok, tostring(err))
    end)
  end
end)

describe('assembly source identity', function()
  it('maps the selected file ID and excludes other files and line zero', function()
    local forward, reverse = require('godbolt.parsers.assembly').parse(
      vim.fn.readfile('testdata/inputs/mapping.s'), '/tmp/example.zig')
    assert.are.same({ [2] = { 3, 4, 8, 9 } }, forward)
    assert.are.same({ [2] = 2, [3] = 2, [4] = 2, [7] = 2, [8] = 2, [9] = 2 }, reverse)
  end)
end)

describe('LLVM source identity', function()
  it('follows lexical scopes and excludes instructions from other source files', function()
    local forward, reverse = require('godbolt.parsers.llvm_ir').parse(
      vim.fn.readfile('testdata/inputs/mapping.ll'), '/tmp/example.zig')
    assert.are.same({ [2] = { 2 } }, forward)
    assert.are.same({ [2] = { line = 2, column = 5 } }, reverse)
  end)
end)
