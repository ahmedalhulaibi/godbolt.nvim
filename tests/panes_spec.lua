local godbolt = require('godbolt')
local panes = require('godbolt.panes')
local cache = require('godbolt.pane_cache')
local compiler = require('godbolt.zig_build')

local function pump() vim.wait(25, function() return false end, 5) end

local function fixture(test)
  local original, compile, notify = vim.deepcopy(godbolt.config), compiler.compile, vim.notify
  local lsp_config = vim.deepcopy(vim.lsp.config.asm_lsp or { cmd = { 'asm-lsp' } })
  panes.close()
  cache.clear()
  local parent_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd('tabnew')
  local tab = vim.api.nvim_get_current_tabpage()
  local source_win = vim.api.nvim_get_current_win()
  local dir = vim.fn.tempname() .. " pane space'quote"
  vim.fn.mkdir(dir .. '/a', 'p')
  vim.fn.mkdir(dir .. '/b', 'p')
  vim.fn.writefile({ 'const std = @import("std");' }, dir .. '/build.zig')
  local a, b, text = dir .. '/a/XDG.zig', dir .. '/b/XDG.zig', dir .. '/notes.txt'
  for _, file in ipairs({ a, b }) do vim.fn.writefile(vim.fn.readfile('testdata/inputs/pane-source.zig'), file) end
  vim.fn.writefile({ 'notes' }, text)
  local jobs, calls, errors = {}, {}, {}
  compiler.compile = function(format, opts)
    local file = vim.api.nvim_buf_get_name(opts.source)
    local job = { format = format, file = file, opts = opts }
    jobs[#jobs + 1], calls[#calls + 1] = job, job
  end
  vim.notify = function(message, level) if level == vim.log.levels.ERROR then errors[#errors + 1] = message end end
  godbolt.setup({ zig = '/usr/bin/true', zig_args = '', zig_build_args = {},
    panes = { debounce_ms = 0, asm_lsp = false }, line_mapping = { enabled = true, auto_scroll = false, throttle_ms = 0 } })
  local ctx = { a = a, b = b, text = text, dir = dir, jobs = jobs, calls = calls, errors = errors, win = source_win, tab = tab }
  function ctx.switch(file)
    vim.api.nvim_set_current_win(source_win)
    vim.cmd('edit ' .. vim.fn.fnameescape(file))
    pump()
  end
  function ctx.outputs()
    local result = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.b[buf].godbolt_pane then
        local format = vim.bo[buf].filetype == 'llvm' and 'llvm' or 'asm'
        assert.is_nil(result[format], 'At most one pane of each format')
        result[format] = { win = win, buf = buf }
      end
    end
    return result
  end
  function ctx.complete(index, error)
    local job = table.remove(jobs, index or 1)
    assert.is_not_nil(job)
    local lines = vim.fn.readfile('testdata/inputs/pane-output.' .. (job.format == 'llvm' and 'll' or 's'))
    for i, line in ipairs(lines) do
      lines[i] = line:gsub('{{directory}}', function() return vim.fs.dirname(job.file) end)
        :gsub('{{filename}}', function() return vim.fn.fnamemodify(job.file, ':t') end)
    end
    job.opts.done(error and { error = error } or { lines = lines, command = 'fixture compiler' })
    pump()
  end
  function ctx.finish()
    -- Give asynchronous fingerprint completion a turn before draining the fake compiler.
    vim.wait(100, function() return false end, 5)
    local count = 0
    while #jobs > 0 do count = count + 1; assert.is_true(count < 30); ctx.complete() end
  end
  function ctx.open(format)
    godbolt.godbolt_zig(format)
    pump()
  end
  function ctx.move(win, row)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { row, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { modeline = false })
    pump()
  end
  local ok, err = pcall(function()
    ctx.switch(a)
    local warmed = false
    cache.fingerprint(vim.api.nvim_get_current_buf(), function() warmed = true end)
    assert.is_true(vim.wait(5000, function() return warmed end, 5))
    test(ctx)
  end)
  vim.api.nvim_set_current_tabpage(tab)
  panes.close()
  cache.clear()
  vim.cmd('tabclose!')
  vim.api.nvim_set_current_tabpage(parent_tab)
  compiler.compile, vim.notify, godbolt.config = compile, notify, original
  vim.lsp.config.asm_lsp = lsp_config
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:sub(1, #dir) == dir then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end
  vim.fn.delete(dir, 'rf')
  assert.is_true(ok, tostring(err))
end

describe('persistent Zig panes', function()
  it('names read-only panes and synchronizes source, assembly, and IR without compiling on focus', function()
    fixture(function(c)
      c.move(c.win, 2)
      c.open('asm'); c.finish()
      c.open('llvm'); c.finish()
      local outputs = c.outputs()
      assert.are.equal(3, #vim.api.nvim_tabpage_list_wins(c.tab))
      for format, p in pairs(outputs) do
        assert.are.equal('XDG.zig.' .. (format == 'llvm' and 'llvmir' or 's'), vim.fn.fnamemodify(vim.api.nvim_buf_get_name(p.buf), ':t'))
        assert.are.equal('nofile', vim.bo[p.buf].buftype)
        assert.is_false(vim.bo[p.buf].modifiable)
        assert.is_true(vim.bo[p.buf].readonly)
      end
      for _, case in ipairs({ { 'source', 4, 4, 6, 5 }, { 'asm', 3, 2, 3, 2 }, { 'llvm', 5, 4, 6, 5 } }) do
        local win = case[1] == 'source' and c.win or outputs[case[1]].win
        c.move(win, case[2])
        assert.are.equal(case[3], vim.api.nvim_win_get_cursor(c.win)[1])
        assert.are.equal(case[4], vim.api.nvim_win_get_cursor(outputs.asm.win)[1])
        assert.are.equal(case[5], vim.api.nvim_win_get_cursor(outputs.llvm.win)[1])
      end
      assert.are.equal(2, #c.calls)
    end)
  end)

  it('keeps temporary assembly files synchronized and removes them across pane lifecycles', function()
    fixture(function(c)
      c.open('asm'); c.finish()
      local first = c.outputs().asm
      local path = vim.api.nvim_buf_get_name(first.buf)
      assert.are.same(vim.api.nvim_buf_get_lines(first.buf, 0, -1, false), vim.fn.readfile(path))
      assert.are.equal('file', vim.uri_from_bufnr(first.buf):match('^(%w+):'))
      c.switch(c.b); c.finish()
      local second = c.outputs().asm
      local next_path = vim.api.nvim_buf_get_name(second.buf)
      assert.are.equal(first.buf, second.buf)
      assert.is_true(path ~= next_path, 'Equal basenames must not share a file URI')
      assert.are.equal(0, vim.fn.filereadable(path))
      assert.are.same(vim.api.nvim_buf_get_lines(second.buf, 0, -1, false), vim.fn.readfile(next_path))
      c.switch(c.text)
      assert.are.same(vim.api.nvim_buf_get_lines(second.buf, 0, -1, false), vim.fn.readfile(vim.api.nvim_buf_get_name(second.buf)))
      c.switch(c.a); c.finish()
      local closed = vim.api.nvim_buf_get_name(first.buf)
      vim.api.nvim_win_close(first.win, true); pump()
      assert.are.equal(0, vim.fn.filereadable(closed))
      c.open('asm'); c.finish()
      closed = vim.api.nvim_buf_get_name(c.outputs().asm.buf)
      panes.close()
      assert.are.equal(0, vim.fn.filereadable(closed))
      c.open('asm'); c.finish()
      closed = vim.api.nvim_buf_get_name(c.outputs().asm.buf)
      vim.api.nvim_buf_delete(c.outputs().asm.buf, { force = true }); pump()
      assert.are.equal(0, vim.fn.filereadable(closed))
      vim.cmd('tabnew ' .. vim.fn.fnameescape(c.a))
      panes.open('asm'); c.finish()
      closed = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
      assert.are.equal(1, vim.fn.filereadable(closed))
      vim.cmd('tabclose!'); pump()
      assert.are.equal(0, vim.fn.filereadable(closed))
    end)
  end)

  it('marks every selected output row in fixed gutters without taking source focus', function()
    fixture(function(c)
      c.move(c.win, 2)
      c.open('asm'); c.finish(); c.open('llvm'); c.finish()
      local outputs = c.outputs()
      local function signs(buf)
        local rows = {}
        for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true, type = 'sign' })) do
          if extmark[4].sign_text then
            assert.are.equal('▶ ', extmark[4].sign_text)
            assert.are.equal('GodboltSelectionSign', extmark[4].sign_hl_group)
            assert.are.equal(200, extmark[4].priority)
            rows[#rows + 1] = extmark[2] + 1
          end
        end
        table.sort(rows)
        return rows
      end
      for _, p in pairs(outputs) do
        assert.are.equal('yes:1', vim.wo[p.win].signcolumn)
        assert.are.equal('%s', vim.wo[p.win].statuscolumn)
      end
      for _, case in ipairs({ { line = 4, asm = { 6, 7 }, llvm = { 5 } },
        { line = 2, asm = { 3, 4 }, llvm = { 2 } }, { line = 1, asm = {}, llvm = {} } }) do
        c.move(c.win, case.line)
        assert.are.equal(c.win, vim.api.nvim_get_current_win())
        assert.are.same(case.asm, signs(outputs.asm.buf))
        assert.are.same(case.llvm, signs(outputs.llvm.buf))
        for _, format in ipairs({ 'asm', 'llvm' }) do
          local p = outputs[format]
          for _, row in ipairs(case[format]) do
            local gutter = vim.api.nvim_eval_statusline(vim.wo[p.win].statuscolumn, { winid = p.win, use_statuscol_lnum = row })
            assert.are.equal('▶ ', gutter.str, 'Marker must render while source window retains focus')
            assert.are.equal(2, gutter.width)
          end
        end
        assert.are.same({}, signs(vim.api.nvim_win_get_buf(c.win)))
      end
      c.move(c.win, 4)
      vim.api.nvim_set_hl(0, 'GodboltSelectionSign', {})
      vim.api.nvim_exec_autocmds('ColorScheme', { modeline = false })
      local highlight = vim.api.nvim_get_hl(0, { name = 'GodboltSelectionSign', link = false })
      assert.is_true(highlight.bold)
      assert.are.equal(vim.o.background == 'dark' and 0xffd75f or 0x9a4200, highlight.fg)
      assert.are.same({ 6, 7 }, signs(outputs.asm.buf))
      c.switch(c.text)
      assert.are.same({}, signs(outputs.asm.buf))
      assert.are.same({}, signs(outputs.llvm.buf))
    end)
  end)

  it('reuses both windows on file switches and restores unchanged results from cache', function()
    fixture(function(c)
      c.open('asm'); c.finish(); c.open('llvm'); c.finish()
      local old = c.outputs()
      c.switch(c.b); c.finish()
      local updated = c.outputs()
      assert.are.same(old, updated)
      for _, p in pairs(updated) do assert.are.equal(c.b, vim.api.nvim_buf_get_name(vim.b[p.buf].godbolt_source_bufnr)) end
      assert.are.equal(4, #c.calls)
      c.switch(c.a); c.finish()
      assert.are.equal(4, #c.calls)
      c.open('asm'); c.open('llvm'); c.finish()
      assert.are.equal(4, #c.calls)
      assert.are.equal(3, #vim.api.nvim_tabpage_list_wins(c.tab))
    end)
  end)

  it('rejects stale asynchronous results and never saves a modified file on switching', function()
    fixture(function(c)
      c.open('asm'); c.finish(); c.open('llvm'); c.finish()
      c.switch(c.b)
      assert.are.equal(2, #c.jobs)
      c.switch(c.a)
      c.complete(1, 'Old source compilation failed')
      c.finish()
      assert.are.equal(0, #c.errors, 'Stale build errors must not affect the active source')
      assert.are.equal(4, #c.calls)
      for _, p in pairs(c.outputs()) do assert.are.equal(c.a, vim.api.nvim_buf_get_name(vim.b[p.buf].godbolt_source_bufnr)) end
      local disk = vim.fn.readfile(c.b)
      c.switch(c.b)
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '    return 9;' })
      vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf, modeline = false }); pump()
      c.finish()
      assert.is_true(vim.bo[buf].modified)
      assert.are.same(disk, vim.fn.readfile(c.b))
      for _, p in pairs(c.outputs()) do
        assert.is_nil(vim.b[p.buf].godbolt_full_output)
        assert.are.same({ '[Godbolt] Unsaved changes: save or run the keymap to refresh' }, vim.api.nvim_buf_get_lines(p.buf, 0, -1, false))
      end
      c.open('asm'); c.finish()
      assert.is_false(vim.bo[buf].modified)
      assert.are.equal('    return 9;', vim.fn.readfile(c.b)[2])
    end)
  end)

  it('defers hidden panes, validates input hashes on showing, and respects compiler arguments', function()
    fixture(function(c)
      c.open('asm'); c.finish(); c.open('llvm'); c.finish()
      local outputs = c.outputs()
      vim.cmd('tabnew')
      local hidden_tab = vim.api.nvim_get_current_tabpage()
      local buf = vim.fn.bufnr(c.a)
      vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '    return 8;' })
      vim.api.nvim_buf_call(buf, function() vim.cmd('write') end)
      pump()
      assert.are.equal(2, #c.calls)
      vim.api.nvim_set_current_tabpage(c.tab); pump(); c.finish()
      assert.are.equal(4, #c.calls)
      assert.are.same(outputs, c.outputs())
      vim.api.nvim_set_current_tabpage(hidden_tab); vim.cmd('tabclose')
      vim.api.nvim_set_current_win(c.win)
      vim.b[buf].godbolt_build_args = { '-Doptimize=ReleaseFast' }
      c.open('asm'); c.finish()
      assert.are.equal(6, #c.calls)
      panes.refresh(); c.finish()
      assert.are.equal(8, #c.calls, 'Force refresh bypasses unchanged cached results')
      c.open('asm'); c.finish()
      assert.are.equal(8, #c.calls)
    end)
  end)

  it('clears output on non-Zig files and redirects file opens from an output pane to the source window', function()
    fixture(function(c)
      c.open('asm'); c.finish(); c.open('llvm'); c.finish()
      local outputs = c.outputs()
      c.switch(c.text)
      assert.are.equal(2, #c.calls)
      for _, p in pairs(c.outputs()) do assert.is_nil(vim.b[p.buf].godbolt_full_output) end
      vim.api.nvim_set_current_win(outputs.asm.win)
      vim.cmd('edit ' .. vim.fn.fnameescape(c.b)); pump(); c.finish()
      assert.are.same(outputs, c.outputs())
      assert.are.equal(c.b, vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(c.win)))
      assert.are.equal(3, #vim.api.nvim_tabpage_list_wins(c.tab))
    end)
  end)

  it('does not compile hidden buffers in the active tab until they are shown', function()
    fixture(function(c)
      c.open('asm'); c.finish(); c.open('llvm'); c.finish()
      local outputs = c.outputs()
      for _, p in pairs(outputs) do vim.api.nvim_win_set_buf(p.win, vim.api.nvim_create_buf(false, true)) end
      vim.api.nvim_set_current_win(c.win)
      local source = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(source, 1, 2, false, { '    return 5;' })
      vim.cmd('write'); pump()
      assert.are.equal(2, #c.calls)
      for _, p in pairs(outputs) do vim.api.nvim_win_set_buf(p.win, p.buf) end
      vim.api.nvim_set_current_win(outputs.asm.win); pump(); c.finish()
      assert.are.equal(4, #c.calls)
      assert.are.same(outputs, c.outputs())
    end)
  end)

  it('hashes project inputs and external paths, and evicts least-recently-used results', function()
    fixture(function(c)
      godbolt.config.panes.cache_entries = 2
      c.open('asm'); c.finish(); c.open('llvm'); c.finish()
      c.switch(c.b); c.finish()
      c.switch(c.a); c.finish()
      assert.are.equal(6, #c.calls)
      local extra = c.dir .. '-external'
      vim.fn.writefile({ 'aaaa' }, extra)
      godbolt.config.panes.cache_paths = { extra }
      c.open('asm'); c.finish()
      assert.are.equal(8, #c.calls)
      vim.fn.writefile({ 'bbbb' }, extra)
      c.open('asm'); c.finish()
      assert.are.equal(10, #c.calls)
      vim.fn.delete(extra)
      vim.fn.writefile({ 'const changed = true;' }, c.dir .. '/build.zig')
      c.open('asm'); c.finish()
      assert.are.equal(12, #c.calls)
      c.switch(c.b); c.finish()
      local outputs = c.outputs()
      for _, p in pairs(outputs) do vim.api.nvim_win_close(p.win, true) end
      pump()
      c.open('asm'); c.finish()
      assert.are.equal(14, #c.calls, 'A closed pane can reuse its cached result')
    end)
  end)

  it('preserves layout, source identity, and cache behavior across generated command sequences', function()
    fixture(function(c)
      local seed, current = 491, c.a
      local function random(n) seed = (seed * 48271) % 2147483647; return (seed % n) + 1 end
      local commands = { 'a', 'b', 'text', 'asm', 'llvm', 'oldest', 'newest', 'source2', 'source4', 'closeasm', 'closellvm' }
      for _ = 1, 120 do
        local command = commands[random(#commands)]
        if command == 'a' or command == 'b' or command == 'text' then
          current = c[command]; c.switch(current)
        elseif command == 'asm' or command == 'llvm' then
          if current ~= c.text then c.open(command) end
        elseif command == 'oldest' or command == 'newest' then
          if #c.jobs > 0 then c.complete(command == 'oldest' and 1 or #c.jobs) end
        elseif command == 'source2' or command == 'source4' then
          if current ~= c.text then c.move(c.win, command == 'source2' and 2 or 4) end
        else
          local p = c.outputs()[command == 'closeasm' and 'asm' or 'llvm']
          if p then vim.api.nvim_win_close(p.win, true); pump() end
        end
        local outputs = c.outputs()
        assert.is_true(#vim.api.nvim_tabpage_list_wins(c.tab) <= 3)
        for format, p in pairs(outputs) do
          assert.is_false(vim.bo[p.buf].modifiable)
          assert.are.equal(current, vim.api.nvim_buf_get_name(vim.b[p.buf].godbolt_source_bufnr))
          local full = vim.b[p.buf].godbolt_full_output
          if full then
            local expected = format == 'asm' and ('\t.file 7 "' .. vim.fs.dirname(current) .. '" "XDG.zig"') or
              ('!0 = !DIFile(filename: "XDG.zig", directory: "' .. vim.fs.dirname(current) .. '")')
            assert.are.equal(expected, full[format == 'asm' and 1 or 7], 'Never show results for the wrong source')
          end
        end
      end
      c.finish()
    end)
  end)
end)

if vim.env.GODBOLT_TEST_ASM_LSP then
  describe('assembly language server', function()
    it('provides hover through a real file URI rooted at the source project', function()
      fixture(function(c)
        godbolt.config.panes.asm_lsp = true
        vim.lsp.config('asm_lsp', { cmd = { vim.env.GODBOLT_TEST_ASM_LSP }, root_dir = c.dir })
        c.open('asm'); c.finish()
        local p = c.outputs().asm
        local client
        for _, source in ipairs({ c.a, c.b, c.a }) do
          c.switch(source); c.finish()
          assert.is_true(vim.wait(30000, function()
            client = vim.lsp.get_clients({ bufnr = p.buf, name = 'asm_lsp' })[1]
            return client and client.initialized
          end, 10))
          assert.are.equal(c.dir, client.config.root_dir)
          assert.is_true(client.config._godbolt_asm)
          assert.are.equal(0, #vim.lsp.get_clients({ bufnr = p.buf, method = 'textDocument/diagnostic' }))
          local response = client:request_sync('textDocument/hover', {
            textDocument = { uri = vim.uri_from_bufnr(p.buf) }, position = { line = 2, character = 2 },
          }, 30000, p.buf)
          assert.is_not_nil(response)
          assert.is_nil(response.err)
          assert.is_not_nil(response.result)
          assert.are.equal('markdown', response.result.contents.kind)
          assert.is_true(#response.result.contents.value > 0)
        end
        local path = vim.api.nvim_buf_get_name(p.buf)
        panes.close()
        assert.are.equal(0, vim.fn.filereadable(path))
        assert.is_true(vim.wait(5000, function() return client:is_stopped() end, 10))
      end)
    end)
  end)
end
