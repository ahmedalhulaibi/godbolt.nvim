local M = {}

function M.detach(p)
  if not p.buf or not vim.api.nvim_buf_is_valid(p.buf) then return end
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = p.buf })) do
    if client.config._godbolt_asm then
      vim.lsp.buf_detach_client(p.buf, client.id)
      if next(client.attached_buffers) == nil then
        client.config._godbolt_asm = false
        client:stop()
      end
    end
  end
end

function M.remove_files(p)
  if p.temp_dir then vim.fn.delete(p.temp_dir, 'rf') end
  p.temp_dir, p.file = nil, nil
end

function M.cleanup(p)
  M.detach(p)
  M.remove_files(p)
end

function M.write(p, source, lines)
  p.temp_dir = p.temp_dir or vim.fn.tempname()
  local file = p.temp_dir .. '/' .. vim.fn.sha256(source):sub(1, 16) .. '/' .. vim.fn.fnamemodify(source, ':t') .. '.s'
  if file ~= p.file then
    M.detach(p)
    if p.file then vim.fn.delete(vim.fs.dirname(p.file), 'rf') end
    vim.fn.mkdir(vim.fs.dirname(file), 'p', 448)
    p.file = file
    vim.api.nvim_buf_set_name(p.buf, file)
  end
  assert(vim.fn.writefile(lines, file) == 0, 'Cannot write temporary assembly file')
end

function M.attach(p, source)
  if not p.file or not require('godbolt').config.panes.asm_lsp then return end
  local cfg = vim.deepcopy(vim.lsp.config.asm_lsp or { cmd = { 'asm-lsp' } })
  if type(cfg.cmd) == 'table' and vim.fn.executable(cfg.cmd[1]) ~= 1 then return end
  local file = p.file
  local function start(root)
    if p.file ~= file or not p.ready_key or not p.buf or not vim.api.nvim_buf_is_valid(p.buf) then return end
    cfg.name, cfg.root_dir, cfg.cmd_cwd = 'asm_lsp', root, cfg.cmd_cwd or root
    cfg._godbolt_asm = true
    local on_init = cfg.on_init
    cfg.on_init = function(client, result)
      if on_init then on_init(client, result) end
      client.server_capabilities.diagnosticProvider = nil
    end
    cfg.handlers = cfg.handlers or {}
    cfg.handlers['textDocument/publishDiagnostics'] = function() end
    local ok, err = pcall(vim.lsp.start, cfg, { bufnr = p.buf, reuse_client = function(client, wanted)
      return client.config._godbolt_asm and client.name == wanted.name and client.config.root_dir == wanted.root_dir
    end })
    if not ok then vim.notify('[Godbolt] asm-lsp: ' .. tostring(err), vim.log.levels.WARN) end
  end
  if type(cfg.root_dir) == 'function' then
    cfg.root_dir(source, start)
  else
    start(cfg.root_dir or vim.fs.root(vim.api.nvim_buf_get_name(source), { '.asm-lsp.toml', 'build.zig', '.git' })
      or vim.fs.dirname(vim.api.nvim_buf_get_name(source)))
  end
end

return M
