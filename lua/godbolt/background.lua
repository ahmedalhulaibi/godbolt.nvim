local M = {}
local workers, pending, sequence = {}, {}, 0
local queue, active = {}, false
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p'))))

function M.receive(id, result)
  local callback = pending[id]
  pending[id] = nil
  for _, worker in pairs(workers) do worker.requests[id] = nil end
  if callback then vim.schedule(function() callback(result) end) end
end

local function start(lane)
  if workers[lane] then return workers[lane] end
  local worker = { requests = {} }
  worker.channel = vim.fn.jobstart({ vim.v.progpath, '--embed', '--headless', '-u', 'NONE', '-n', '-i', 'NONE' }, {
    rpc = true,
    on_exit = function()
      if workers[lane] == worker then workers[lane] = nil end
      for id in pairs(worker.requests) do M.receive(id, { error = 'Godbolt background worker exited' }) end
    end,
  })
  assert(worker.channel > 0, 'Cannot start Godbolt background worker')
  workers[lane] = worker
  vim.rpcnotify(worker.channel, 'nvim_exec_lua', 'vim.opt.runtimepath:prepend(...)', { root })
  return worker
end

function M.call(operation, source, done)
  local cfg = require('godbolt').config
  local payload = {
    file = source and vim.api.nvim_buf_get_name(source) or nil,
    build_args = source and vim.b[source].godbolt_build_args or nil,
    cwd = vim.fn.getcwd(), env = vim.fn.environ(),
    config = { zig = cfg.zig, zig_args = cfg.zig_args, zig_build_args = cfg.zig_build_args,
      panes = { cache_paths = cfg.panes.cache_paths } },
  }
  sequence = sequence + 1
  local id = sequence
  pending[id] = done
  local ok, err = pcall(function()
    local lane = operation == 'fingerprint' and 'fingerprint' or 'compile'
    local worker = start(lane)
    worker.requests[id] = true
    vim.rpcnotify(worker.channel, 'nvim_exec_lua',
      'require("godbolt.background").execute(...)', { id, operation, payload })
  end)
  if not ok then M.receive(id, { error = tostring(err) }) end
end

local drain
drain = function()
  if active or #queue == 0 then return end
  active = true
  local job = table.remove(queue, 1)
  local function finish(result)
    pcall(vim.rpcnotify, 1, 'nvim_exec_lua', 'require("godbolt.background").receive(...)', { job.id, result })
    active = false
    vim.schedule(drain)
  end
  local ok, err = pcall(function()
    local data = job.payload
    for name in pairs(vim.fn.environ()) do if not data.env[name] then vim.env[name] = nil end end
    for name, value in pairs(data.env) do vim.env[name] = value end
    vim.api.nvim_set_current_dir(data.cwd)
    require('godbolt').setup(data.config)
    if job.operation == 'clear' then
      require('godbolt.pane_cache').clear_local()
      finish({})
      return
    end
    vim.cmd('edit! ' .. vim.fn.fnameescape(data.file))
    local source = vim.api.nvim_get_current_buf()
    vim.b[source].godbolt_build_args = data.build_args
    if job.operation == 'fingerprint' then
      finish({ key = require('godbolt.pane_cache').fingerprint_sync(source) })
    else
      require('godbolt.zig_build').compile_worker(job.operation, {
        source = source, current = function() return true end,
        done = function(result)
          if result.lines then
            local valid, fingerprint = pcall(require('godbolt.pane_cache').fingerprint_sync, source)
            if valid then result.fingerprint = fingerprint else result.error = tostring(fingerprint) end
          end
          finish(result)
        end,
      })
    end
  end)
  if not ok then finish({ error = tostring(err) }) end
end

function M.execute(id, operation, payload)
  queue[#queue + 1] = { id = id, operation = operation, payload = payload }
  vim.schedule(drain)
end

function M.clear()
  for _, worker in pairs(workers) do
    vim.rpcnotify(worker.channel, 'nvim_exec_lua', 'require("godbolt.pane_cache").clear_local()', {})
  end
end

vim.api.nvim_create_autocmd('VimLeavePre', { callback = function()
  for _, worker in pairs(workers) do vim.fn.jobstop(worker.channel) end
end })

return M
