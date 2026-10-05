local M = {}
local sessions, formats = {}, { 'asm', 'llvm' }
local cache = require('godbolt.pane_cache')
local request, activate
local group

local function config() return require('godbolt').config end
local function valid_buf(buf) return buf and vim.api.nvim_buf_is_valid(buf) end
local function valid_win(win) return win and vim.api.nvim_win_is_valid(win) end
local function live(s) return sessions[s.tab] == s and vim.api.nvim_tabpage_is_valid(s.tab) end
local function visible(s, p)
  return s.tab == vim.api.nvim_get_current_tabpage() and valid_win(p.win) and
    vim.api.nvim_win_get_buf(p.win) == p.buf
end
local function available(s, p)
  return s.tab == vim.api.nvim_get_current_tabpage() and (p.want_open or visible(s, p))
end
local function source_ok(s)
  return valid_buf(s.source) and vim.bo[s.source].buftype == '' and
    vim.api.nvim_buf_get_name(s.source):match('%.zig$') and not vim.bo[s.source].modified
end
local function clear(buf, ns)
  if valid_buf(buf) then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
end

local function position(s, win, line, column)
  if not valid_win(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  if line < 1 or line > vim.api.nvim_buf_line_count(buf) then return end
  local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ''
  column = math.min(math.max(column or 0, 0), #text)
  if not vim.deep_equal(vim.api.nvim_win_get_cursor(win), { line, column }) then
    s.programmed[win] = { buf = buf, line = line, column = column }
    vim.api.nvim_win_set_cursor(win, { line, column })
  end
end

local function mark(buf, ns, lines, cursor, source_line)
  if not valid_buf(buf) then return end
  local count = vim.api.nvim_buf_line_count(buf)
  for _, line in ipairs(lines) do
    if line > 0 and line <= count then
      vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {
        line_hl_group = cursor and 'GodboltCursor' or ('GodboltLevel' .. ((((source_line or line) - 1) % 5) + 1)),
      })
    end
  end
end

local function highlights(s)
  clear(s.source, s.static_ns)
  local source_lines = {}
  for _, format in ipairs(formats) do
    local p = s.panes[format]
    if p then
      clear(p.buf, s.static_ns)
      for line, rows in pairs(p.forward) do source_lines[line] = true; mark(p.buf, s.static_ns, rows, false, line) end
    end
  end
  mark(s.source, s.static_ns, vim.tbl_keys(source_lines), false)
end

local function sync(s, win)
  if not live(s) or not source_ok(s) or config().line_mapping.enabled == false then return end
  clear(s.source, s.cursor_ns)
  for _, format in ipairs(formats) do
    local p = s.panes[format]
    if p then clear(p.buf, s.cursor_ns) end
  end
  if not valid_win(win) then return end
  local buf = vim.api.nvim_win_get_buf(win)
  local row, column = unpack(vim.api.nvim_win_get_cursor(win))
  local source_line, source_column
  if buf == s.source then source_line, source_column = row, column
  else
    for _, format in ipairs(formats) do
      local p = s.panes[format]
      if p and p.buf == buf then
        local location = p.reverse[row]
        if type(location) == 'table' then
          source_line, source_column = location.line, math.max((location.column or 1) - 1, 0)
        else source_line, source_column = location, 0 end
        break
      end
    end
  end
  if not source_line then return end
  mark(s.source, s.cursor_ns, { source_line }, true)
  if win ~= s.source_win then position(s, s.source_win, source_line, source_column) end
  for _, format in ipairs(formats) do
    local p = s.panes[format]
    local rows = p and p.forward[source_line]
    if rows and #rows > 0 then
      mark(p.buf, s.cursor_ns, rows, true)
      if p.win ~= win then
        position(s, p.win, rows[1], 0)
        if config().line_mapping.auto_scroll and visible(s, p) then
          vim.api.nvim_win_call(p.win, function() vim.cmd('normal! zz') end)
        end
      end
    end
  end
end

local function title(s, p)
  if not valid_buf(p.buf) then return end
  local file = valid_buf(s.source) and vim.api.nvim_buf_get_name(s.source) or '[no source]'
  local name = file .. (p.format == 'llvm' and '.llvmir' or '.asm')
  vim.api.nvim_buf_set_name(p.buf, 'godbolt://' .. s.tab .. '/' .. p.buf .. '/' .. name)
  vim.b[p.buf].godbolt_source_bufnr = s.source
  if visible(s, p) then vim.wo[p.win].winbar = vim.fn.fnamemodify(name, ':t'):gsub('%%', '%%%%') end
end

local function write(s, p, lines, full, display_map)
  if not valid_buf(p.buf) then return end
  s.internal = true
  vim.bo[p.buf].readonly = false
  vim.bo[p.buf].modifiable = true
  vim.api.nvim_buf_set_lines(p.buf, 0, -1, false, #lines > 0 and lines or { '' })
  vim.bo[p.buf].modified = false
  vim.bo[p.buf].modifiable = false
  vim.bo[p.buf].readonly = true
  vim.b[p.buf].godbolt_full_output = full
  vim.b[p.buf].godbolt_line_map = display_map
  title(s, p)
  s.internal = false
end

local function placeholder(s, p, message)
  p.forward, p.reverse, p.ready_key = {}, {}, nil
  clear(p.buf, s.cursor_ns)
  clear(p.buf, s.static_ns)
  write(s, p, { message }, nil, nil)
end

local function render(s, p, data, key)
  if not visible(s, p) then
    if not p.want_open then return end
    s.internal = true
    if not valid_buf(p.buf) then p.buf = vim.api.nvim_create_buf(false, true) end
    vim.bo[p.buf].buftype = 'nofile'
    vim.bo[p.buf].bufhidden = 'hide'
    vim.bo[p.buf].swapfile = false
    vim.bo[p.buf].filetype = p.format == 'llvm' and 'llvm' or 'asm'
    vim.b[p.buf].godbolt_pane = true
    local function attach()
      vim.api.nvim_win_set_buf(p.win, p.buf)
      vim.wo[p.win].number = false
      vim.wo[p.win].relativenumber = false
    end
    if valid_win(p.win) then attach()
    else
      vim.api.nvim_win_call(s.source_win, function()
        vim.cmd(config().window_cmd or 'vertical botright split')
        p.win = vim.api.nvim_get_current_win()
        attach()
      end)
    end
    s.internal = false
  end
  local displayed, display_map = data.lines, nil
  if p.format == 'llvm' and config().display.strip_debug_metadata then
    displayed, display_map = require('godbolt.ir_utils').filter_debug_metadata(data.lines)
  end
  write(s, p, displayed, data.lines, display_map)
  local parser = require('godbolt.parsers.' .. (p.format == 'llvm' and 'llvm_ir' or 'assembly'))
  local forward, reverse = parser.parse(data.lines, vim.api.nvim_buf_get_name(s.source))
  local original_to_display = {}
  for row = 1, #displayed do original_to_display[display_map and display_map[row] or row] = row end
  p.forward, p.reverse = {}, {}
  for line, rows in pairs(forward) do
    for _, original in ipairs(rows) do
      local row = original_to_display[original]
      if row then
        p.forward[line] = p.forward[line] or {}
        table.insert(p.forward[line], row)
      end
    end
  end
  for original, location in pairs(reverse) do
    local row = original_to_display[original]
    if row then p.reverse[row] = location end
  end
  p.ready_key, p.want_open = key, false
  highlights(s)
  sync(s, s.source_win)
  if p.focus then vim.api.nvim_set_current_win(p.win) end
  p.focus = false
  vim.api.nvim_exec_autocmds('User', { pattern = 'Godbolt', modeline = false })
end

request = function(s, p)
  if not live(s) or not source_ok(s) or not available(s, p) or not s.key then return end
  local key = s.key .. ':' .. p.format
  if p.ready_key == key and visible(s, p) then
    sync(s, s.source_win)
    if p.focus then vim.api.nvim_set_current_win(p.win); p.focus = false end
    p.want_open = false
    return
  end
  local cached = cache.get(key)
  if cached then render(s, p, cached, key); return end
  if p.pending then p.again = true; return end
  p.pending, p.again = true, false
  local epoch, source, tick = s.epoch, s.source, s.tick
  local function current()
    return live(s) and s.panes[p.format] == p and s.epoch == epoch and available(s, p) and
      s.source == source and valid_buf(source) and vim.api.nvim_buf_get_changedtick(source) == tick
  end
  s.internal = true
  require('godbolt.zig_build').compile(p.format, {
    source = source, current = current,
    done = function(data)
      p.pending = false
      if not live(s) or s.panes[p.format] ~= p then return end
      if not current() or data.cancelled then
        s.dirty = true
        if source_ok(s) and p.again then request(s, p) end
        return
      end
      if data.error then
        placeholder(s, p, '[Godbolt] ' .. data.error)
        vim.notify('[Godbolt] ' .. data.error, vim.log.levels.ERROR)
        if not p.buf then s.panes[p.format] = nil end
      else
        p.pending = true
        local function verified(fingerprint, err)
          p.pending = false
          if not current() then
            if p.again then request(s, p) end
            return
          end
          if err or fingerprint ~= s.key then
            s.dirty = true
            activate(s, s.source_win, source, true)
            return
          end
          cache.put(key, data)
          render(s, p, data, key)
        end
        if data.fingerprint then verified(data.fingerprint)
        else cache.fingerprint(source, verified) end
      end
    end,
  })
  s.internal = false
end

local validate
validate = function(s)
  if s.hash_pending or not live(s) then return end
  local validation = s.validation
  if not validation or not source_ok(s) then return end
  s.hash_pending = true
  cache.fingerprint(validation.source, function(key, err)
    s.hash_pending = false
    if not live(s) then return end
    if s.validation ~= validation then validate(s); return end
    if not source_ok(s) or vim.api.nvim_buf_get_changedtick(validation.source) ~= validation.tick then return end
    local previous_key = s.key
    s.key, s.hash_error = key, err
    if key ~= previous_key and previous_key then
      s.epoch = s.epoch + 1
      for _, format in ipairs(formats) do
        local p = s.panes[format]
        if p then placeholder(s, p, '[Godbolt] Loading…'); p.again = true end
      end
    end
    if err then
      for _, format in ipairs(formats) do
        local p = s.panes[format]
        if p then
          placeholder(s, p, '[Godbolt] ' .. err)
          if not p.buf then s.panes[format] = nil end
        end
      end
      vim.notify('[Godbolt] ' .. err, vim.log.levels.ERROR)
      return
    end
    if not validation.automatic or config().panes.auto_refresh then
      for _, format in ipairs(formats) do
        local p = s.panes[format]
        if p then request(s, p) end
      end
    end
  end)
end

activate = function(s, win, source, automatic)
  if not live(s) or s.internal or not valid_buf(source) then return end
  local tick = vim.api.nvim_buf_get_changedtick(source)
  local previous_source = s.source
  local changed = previous_source ~= source or s.tick ~= tick
  s.source_win, s.source, s.tick = win, source, tick
  local has_visible = false
  for _, format in ipairs(formats) do
    local p = s.panes[format]
    if p and available(s, p) then has_visible = true end
  end
  local eligible = source_ok(s) and has_visible
  local invalidate = changed or not eligible or s.dirty or not s.key
  s.dirty = false
  s.debounce = s.debounce + 1
  local generation = s.debounce
  s.validation = eligible and { source = source, tick = tick, automatic = automatic } or nil
  if invalidate then
    s.epoch = s.epoch + 1
    s.key = nil
    clear(previous_source, s.static_ns)
    clear(previous_source, s.cursor_ns)
    local message = not vim.api.nvim_buf_get_name(source):match('%.zig$') and '[Godbolt] Open a Zig source file' or
      (vim.bo[source].modified and '[Godbolt] Unsaved changes: save or run the keymap to refresh' or '[Godbolt] Loading…')
    for _, format in ipairs(formats) do
      local p = s.panes[format]
      if p then
        placeholder(s, p, message)
        p.again = true
        if automatic then p.focus = false end
      end
    end
  end
  if not eligible then return end
  if automatic then
    vim.defer_fn(function()
      if not live(s) or s.debounce ~= generation then return end
      validate(s)
    end, config().panes.debounce_ms)
  else validate(s) end
end

local function entered(args)
  local s = sessions[vim.api.nvim_get_current_tabpage()]
  if not s or s.internal then return end
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  for _, format in ipairs(formats) do
    local p = s.panes[format]
    if p and valid_win(p.win) and vim.api.nvim_win_get_buf(p.win) ~= p.buf then p.hidden = true end
  end
  if args and args.event == 'TabEnter' then s.dirty = true end
  if vim.b[buf].godbolt_pane then
    for _, format in ipairs(formats) do
      local p = s.panes[format]
      if p and p.buf == buf and (p.hidden or not visible(s, p)) then
        p.win = win
        p.hidden = false
        s.dirty = true
      end
      if p and p.buf == buf and not p.ready_key then s.dirty = true end
    end
    if s.dirty and valid_win(s.source_win) then activate(s, s.source_win, s.source, true) end
    return
  end
  for _, format in ipairs(formats) do
    local p = s.panes[format]
    if p and p.win == win and p.buf ~= buf then p.hidden = true end
  end
  if vim.bo[buf].buftype ~= '' then return end
  for _, format in ipairs(formats) do
    local p = s.panes[format]
    if p and p.win == win and p.buf ~= buf then
      if valid_win(s.source_win) and s.source_win ~= win then
        s.internal = true
        vim.api.nvim_win_set_buf(s.source_win, buf)
        vim.api.nvim_win_set_buf(win, p.buf)
        vim.api.nvim_set_current_win(s.source_win)
        s.internal = false
        p.hidden = false
        win = s.source_win
      else p.win = nil end
      break
    end
  end
  activate(s, win, buf, true)
end

local function install()
  if group then return end
  group = vim.api.nvim_create_augroup('GodboltPanes', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'TabEnter' }, { group = group, callback = entered })
  vim.api.nvim_create_autocmd({ 'BufWritePost', 'TextChanged', 'TextChangedI' }, {
    group = group, callback = function(args)
      if not valid_buf(args.buf) or vim.bo[args.buf].buftype ~= '' then return end
      for _, s in pairs(sessions) do
        if not s.internal and valid_buf(s.source) then
          s.dirty = true
          if s.tab == vim.api.nvim_get_current_tabpage() then activate(s, s.source_win, s.source, true) end
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd('CursorMoved', { group = group, callback = function()
    local s = sessions[vim.api.nvim_get_current_tabpage()]
    if not s or s.internal then return end
    local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    local row, column = unpack(vim.api.nvim_win_get_cursor(win))
    local programmed = s.programmed[win]
    s.programmed[win] = nil
    if programmed and programmed.buf == buf and programmed.line == row and programmed.column == column then return end
    s.cursor_epoch = s.cursor_epoch + 1
    local epoch = s.cursor_epoch
    vim.defer_fn(function()
      if live(s) and epoch == s.cursor_epoch and valid_win(win) and vim.api.nvim_win_get_buf(win) == buf then sync(s, win) end
    end, config().line_mapping.throttle_ms)
  end })
  vim.api.nvim_create_autocmd('WinClosed', { group = group, callback = function(args)
    local win = tonumber(args.match)
    for _, s in pairs(sessions) do
      if not s.internal then
        for _, format in ipairs(formats) do
          local p = s.panes[format]
          if p and p.win == win then
            s.panes[format] = nil
            vim.schedule(function() if valid_buf(p.buf) then vim.api.nvim_buf_delete(p.buf, { force = true }) end end)
            highlights(s)
            if next(s.panes) == nil then
              clear(s.source, s.cursor_ns)
              sessions[s.tab] = nil
            end
          end
        end
      end
    end
  end })
  vim.api.nvim_create_autocmd('BufWipeout', { group = group, callback = function(args)
    for _, s in pairs(sessions) do
      if s.source == args.buf then
        clear(s.source, s.static_ns)
        clear(s.source, s.cursor_ns)
        s.source, s.key = nil, nil
        s.epoch = s.epoch + 1
        for _, format in ipairs(formats) do
          local p = s.panes[format]
          if p then placeholder(s, p, '[Godbolt] Source closed') end
        end
      end
    end
  end })
  vim.api.nvim_create_autocmd('TabClosed', { group = group, callback = function()
    for tab, s in pairs(sessions) do
      if not vim.api.nvim_tabpage_is_valid(tab) then
        sessions[tab] = nil
        clear(s.source, s.static_ns)
        clear(s.source, s.cursor_ns)
      end
    end
  end })
end

function M.open(format)
  if format ~= 'asm' and format ~= 'llvm' then
    vim.notify('[Godbolt] Output must be asm or llvm', vim.log.levels.ERROR)
    return
  end
  install()
  local tab = vim.api.nvim_get_current_tabpage()
  local s = sessions[tab]
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  if vim.b[buf].godbolt_pane and s then sync(s, win); win, buf = s.source_win, s.source end
  if not valid_win(win) or not valid_buf(buf) or vim.bo[buf].buftype ~= '' or not vim.api.nvim_buf_get_name(buf):match('%.zig$') then
    vim.notify('[Godbolt] Open a saved Zig source file first', vim.log.levels.ERROR)
    return
  end
  if not s then
    s = { tab = tab, panes = {}, epoch = 0, debounce = 0, cursor_epoch = 0, programmed = {} }
    s.static_ns = vim.api.nvim_create_namespace('godbolt_panes_static_' .. tab)
    s.cursor_ns = vim.api.nvim_create_namespace('godbolt_panes_cursor_' .. tab)
    sessions[tab] = s
  end
  s.internal = true
  if vim.bo[buf].modified then
    local ok, err = pcall(vim.api.nvim_buf_call, buf, function() vim.cmd('write') end)
    if not ok then s.internal = false; vim.notify('[Godbolt] ' .. tostring(err), vim.log.levels.ERROR); return end
  end
  s.internal = false
  local p = s.panes[format]
  if not p then p = { format = format, forward = {}, reverse = {} }; s.panes[format] = p end
  p.want_open, p.focus = true, true
  for _, other in ipairs(formats) do
    if other ~= format and s.panes[other] then s.panes[other].focus = false end
  end
  activate(s, win, buf, false)
  require('godbolt.highlight').setup()
  return p.buf
end

function M.close()
  local tab = vim.api.nvim_get_current_tabpage()
  local s = sessions[tab]
  if not s then return end
  sessions[tab] = nil
  clear(s.source, s.static_ns)
  clear(s.source, s.cursor_ns)
  if valid_win(s.source_win) then vim.api.nvim_set_current_win(s.source_win) end
  for _, format in ipairs(formats) do
    local p = s.panes[format]
    if p then
      if valid_win(p.win) then
        if #vim.api.nvim_tabpage_list_wins(tab) > 1 then vim.api.nvim_win_close(p.win, true)
        else vim.api.nvim_win_set_buf(p.win, vim.api.nvim_create_buf(true, false)) end
      end
      if valid_buf(p.buf) then vim.api.nvim_buf_delete(p.buf, { force = true }) end
    end
  end
end

function M.refresh()
  cache.clear()
  local s = sessions[vim.api.nvim_get_current_tabpage()]
  if not s then return end
  s.dirty = true
  s.key = nil
  for _, format in ipairs(formats) do if s.panes[format] then M.open(format); break end end
end

return M
