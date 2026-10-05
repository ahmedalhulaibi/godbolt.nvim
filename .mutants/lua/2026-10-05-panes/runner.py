import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

root = Path.cwd()
mutants = [
    ('cache_hit', 'lua/godbolt/pane_cache.lua', 'local entry = entries[key]', 'local entry = nil'),
    ('source_identity', 'lua/godbolt/pane_cache.lua', "local components = { file, build or ''", "local components = { build or ''"),
    ('content_hash', 'lua/godbolt/pane_cache.lua', 'local hash = vim.fn.sha256(vim.base64.encode(bytes))', "local hash = 'unchanged'"),
    ('argument_hash', 'lua/godbolt/pane_cache.lua', 'vim.json.encode(vim.b[source].godbolt_build_args or config.zig_build_args)', "'ignored arguments'"),
    ('visibility', 'lua/godbolt/panes.lua', 'return s.tab == vim.api.nvim_get_current_tabpage() and (p.want_open or visible(s, p))', 'return true'),
    ('stale_result', 'lua/godbolt/panes.lua', 'if not current() or data.cancelled then', 'if false then'),
    ('source_sync', 'lua/godbolt/panes.lua', 'position(s, s.source_win, source_line, source_column)', 'do end'),
    ('output_sync', 'lua/godbolt/panes.lua', 'position(s, p.win, rows[1], 0)', '-- omit output cursor synchronization'),
    ('readonly', 'lua/godbolt/panes.lua', 'vim.bo[p.buf].modifiable = false', 'vim.bo[p.buf].modifiable = true'),
    ('cache_eviction', 'lua/godbolt/pane_cache.lua', 'while vim.tbl_count(entries) > limit do', 'while false do'),
]

def check(directory):
    result = subprocess.run(['./scripts/test', 'tests/panes_spec.lua'], cwd=directory,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
    total = re.search(r'Total:\s+(\d+)', result.stdout)
    failed = re.search(r'Failed:\s+(\d+)', result.stdout)
    assert total and int(total[1]) == 8 and failed, result.stdout[-2000:]
    return result.returncode, int(failed[1])

assert check(root) == (0, 0), 'Baseline must pass'
results = []
for name, file, old, new in mutants:
    with tempfile.TemporaryDirectory(prefix='godbolt-pane-mutant-') as directory:
        target = Path(directory) / 'repo'
        shutil.copytree(root, target, ignore=shutil.ignore_patterns('.git', '.mutants', '.zig-cache', 'zig-out', 'zig-pkg'))
        path = target / file
        text = path.read_text()
        assert text.count(old) == 1, name
        path.write_text(text.replace(old, new))
        status, failed = check(target)
        entry = {'mutant': name, 'file': file, 'failed_tests': failed,
                 'status': 'killed' if status != 0 and failed > 0 else 'survived'}
        print(name, entry['status'], flush=True)
        results.append(entry)
report = root / '.mutants/lua/2026-10-05-panes/outcomes.json'
report.write_text(json.dumps({'method': 'bounded manual mutation; isolated copies; eight boundary tests',
                             'results': results}, indent=2) + '\n')
assert all(entry['status'] == 'killed' for entry in results)
