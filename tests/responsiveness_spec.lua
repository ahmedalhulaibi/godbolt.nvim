describe('Zig pane responsiveness', function()
  for _, case in ipairs({ { name = 'standalone assembly', format = 'asm' },
    { name = 'project IR', format = 'llvm', project = true } }) do
  it('keeps input responsive during ' .. case.name, function()
    local godbolt = require('godbolt')
    local original = vim.deepcopy(godbolt.config)
    local parent = vim.api.nvim_get_current_tabpage()
    vim.cmd('tabnew')
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local file = dir .. '/source.zig'
    vim.fn.writefile(vim.fn.readfile('testdata/inputs/pane-source.zig'), file)
    if case.project then
      vim.fn.mkdir(dir .. '/src', 'p')
      vim.fn.writefile(vim.fn.readfile('testdata/inputs/zig_project/build.zig'), dir .. '/build.zig')
      for _, name in ipairs({ 'main.zig', 'helper.zig' }) do
        vim.fn.writefile(vim.fn.readfile('testdata/inputs/zig_project/src/' .. name), dir .. '/src/' .. name)
      end
      file = dir .. '/src/main.zig'
    end
    local executable = dir .. '/zig'
    vim.fn.writefile(vim.fn.readfile('testdata/inputs/slow-zig.sh'), executable)
    vim.fn.setfperm(executable, 'rwx------')
    vim.env.GODBOLT_TEST_ZIG = vim.env.GODBOLT_TEST_ZIG or vim.fn.exepath('zig')
    local timer
    local ok, err = pcall(function()
      vim.cmd('edit ' .. vim.fn.fnameescape(file))
      godbolt.setup({ zig = executable })
      local before = (vim.uv or vim.loop).hrtime()
      local source = vim.api.nvim_get_current_buf()
      local ticks, max_gap, previous = 0, 0, (vim.uv or vim.loop).hrtime()
      timer = (vim.uv or vim.loop).new_timer()
      timer:start(10, 10, vim.schedule_wrap(function()
        local now = (vim.uv or vim.loop).hrtime()
        max_gap = math.max(max_gap, (now - previous) / 1e6)
        previous, ticks = now, ticks + 1
      end))
      godbolt.godbolt_zig(case.format)
      local elapsed = ((vim.uv or vim.loop).hrtime() - before) / 1e6
      assert.is_true(elapsed < 150, 'Starting compilation must return before the slow tool completes')
      vim.api.nvim_feedkeys('l', 'nx', false)
      assert.is_true(vim.wait(200, function() return vim.api.nvim_win_get_cursor(0)[2] == 1 end, 5), 'Normal-mode input must execute while work is pending')
      assert.is_true(vim.wait(15000, function()
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.b[buf].godbolt_source_bufnr == source and vim.b[buf].godbolt_full_output then return true end
        end
        return false
      end, 10))
      timer:stop(); timer:close()
      timer = nil
      assert.is_true(ticks >= 30, 'UI event loop must keep ticking during slow version and compile commands')
      assert.is_true(max_gap < 200, 'No slow version, compiler, or result scan may run on the UI thread')
    end)
    if timer then timer:stop(); timer:close() end
    require('godbolt.panes').close()
    require('godbolt.pane_cache').clear()
    godbolt.config = original
    vim.cmd('tabclose!')
    vim.api.nvim_set_current_tabpage(parent)
    vim.fn.delete(dir, 'rf')
    assert.is_true(ok, tostring(err))
  end)
  end
end)
