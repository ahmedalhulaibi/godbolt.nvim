local M = {}
local entries, clock, hashes = {}, 0, {}
local uv = vim.uv or vim.loop
local excluded = { ['.git'] = true, ['.zig-cache'] = true, ['zig-cache'] = true,
  ['zig-out'] = true, ['zig-pkg'] = true, ['.mutants'] = true }

local function digest(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then return nil end
  local signature = vim.json.encode({ stat.size, stat.mtime, stat.ctime, stat.ino })
  local old = hashes[path]
  if old and old.signature == signature then return old.hash end
  local fd = assert(uv.fs_open(path, 'r', 438))
  local bytes = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  assert(bytes, 'Cannot read build input: ' .. path)
  local hash = vim.fn.sha256(vim.base64.encode(bytes))
  hashes[path] = { signature = signature, hash = hash }
  return hash
end

local function collect(path, files)
  local stat = uv.fs_stat(path)
  if not stat then return end
  if stat.type == 'file' then files[path] = true; return end
  if stat.type ~= 'directory' then return end
  for name, kind in vim.fs.dir(path) do
    if not excluded[name] then
      local child = path .. '/' .. name
      if kind == 'directory' then collect(child, files)
      elseif kind == 'file' then files[child] = true end
    end
  end
end

function M.fingerprint(source)
  local config = require('godbolt').config
  local file = vim.api.nvim_buf_get_name(source)
  local build = vim.fs.find('build.zig', { path = vim.fs.dirname(file), upward = true, type = 'file' })[1]
  local root = build and vim.fs.dirname(build) or vim.fs.dirname(file)
  local files = { [file] = true }
  if build then
    local listing = vim.system({ 'git', '-C', root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard' },
      { text = false }):wait()
    if listing.code == 0 then
      for name in (listing.stdout or ''):gmatch('[^%z]+') do
        local first = name:match('^[^/]+')
        if not excluded[first] then files[root .. '/' .. name] = true end
      end
    else
      collect(root, files)
    end
  end
  for _, path in ipairs(config.panes.cache_paths) do
    collect(path:sub(1, 1) == '/' and path or (root .. '/' .. path), files)
  end
  local paths = vim.tbl_keys(files)
  table.sort(paths)
  local components = { file, build or '', config.zig, config.zig_args,
    vim.json.encode(vim.b[source].godbolt_build_args or config.zig_build_args) }
  local version = vim.system({ config.zig, 'version' }, { cwd = root, text = true }):wait()
  assert(version.code == 0, version.stderr or 'Cannot identify Zig compiler')
  components[#components + 1] = version.stdout or ''
  components[#components + 1] = vim.env.ZIG_LIB_DIR or ''
  for _, path in ipairs(paths) do
    components[#components + 1] = path
    components[#components + 1] = digest(path) or '[missing]'
  end
  return vim.fn.sha256(vim.json.encode(components))
end

function M.get(key)
  local entry = entries[key]
  if entry then clock = clock + 1; entry.used = clock; return entry.data end
end

function M.put(key, data)
  clock = clock + 1
  entries[key] = { data = data, used = clock }
  local limit = math.max(0, math.floor(require('godbolt').config.panes.cache_entries))
  while vim.tbl_count(entries) > limit do
    local oldest
    for candidate, entry in pairs(entries) do
      if not oldest or entry.used < entries[oldest].used then oldest = candidate end
    end
    entries[oldest] = nil
  end
end

function M.clear() entries, hashes = {}, {} end
return M
