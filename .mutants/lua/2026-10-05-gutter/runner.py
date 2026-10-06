import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

root = Path.cwd()
mutants = [
    ('selection_sign', 'lua/godbolt/panes.lua', "sign_text = output_selection and '▶' or nil", 'sign_text = nil'),
    ('fixed_gutter', 'lua/godbolt/panes.lua', "vim.wo[p.win].signcolumn = 'yes:1'", "vim.wo[p.win].signcolumn = 'no'"),
    ('native_gutter', 'lua/godbolt/panes.lua', "vim.wo[p.win].statuscolumn = '%s'", "vim.wo[p.win].statuscolumn = ' '"),
    ('stale_signs', 'lua/godbolt/panes.lua', 'if p then clear(p.buf, s.cursor_ns) end', 'if false then clear(p.buf, s.cursor_ns) end'),
]

def check(directory):
    result = subprocess.run(['./scripts/test', 'tests/panes_spec.lua'], cwd=directory,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
    total = re.search(r'Total:\s+(\d+)', result.stdout)
    failed = re.search(r'Failed:\s+(\d+)', result.stdout)
    assert total and int(total[1]) == 9 and failed, result.stdout[-2000:]
    return result.returncode, int(failed[1])

assert check(root) == (0, 0)
results = []
for name, file, old, new in mutants:
    with tempfile.TemporaryDirectory(prefix='godbolt-gutter-mutant-') as directory:
        target = Path(directory) / 'repo'
        shutil.copytree(root, target, ignore=shutil.ignore_patterns('.git', '.mutants', '.zig-cache', 'zig-out', 'zig-pkg'))
        path = target / file
        text = path.read_text()
        assert text.count(old) == 1
        path.write_text(text.replace(old, new))
        status, failed = check(target)
        results.append({'mutant': name, 'failed_tests': failed,
                        'status': 'killed' if status != 0 and failed > 0 else 'survived'})
        print(name, results[-1]['status'], flush=True)
(root / '.mutants/lua/2026-10-05-gutter/outcomes.json').write_text(json.dumps({'results': results}, indent=2) + '\n')
assert all(result['status'] == 'killed' for result in results)
