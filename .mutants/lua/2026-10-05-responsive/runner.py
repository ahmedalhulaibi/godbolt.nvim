import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

root = Path.cwd()
assert os.environ.get('GODBOLT_TEST_ZIG')
mutants = [
    ('ui_fingerprint', 'lua/godbolt/pane_cache.lua',
     "require('godbolt.background').call('fingerprint', source, function(result) done(result.key, result.error) end)",
     'done(M.fingerprint_sync(source))'),
    ('ui_compiler', 'lua/godbolt/zig_build.lua',
     "require('godbolt.background').call(output_type, opts.source, function(result)",
     'M.compile_worker(output_type, { source = opts.source, current = opts.current, done = function(result)'),
]

def check(directory):
    result = subprocess.run(['./scripts/test', 'tests/responsiveness_spec.lua'], cwd=directory,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
    total = re.search(r'Total:\s+(\d+)', result.stdout)
    failed = re.search(r'Failed:\s+(\d+)', result.stdout)
    assert total and int(total[1]) == 2 and failed, result.stdout[-3000:]
    return result.returncode, int(failed[1])

assert check(root) == (0, 0)
results = []
for name, file, old, new in mutants:
    with tempfile.TemporaryDirectory(prefix='godbolt-responsive-mutant-') as directory:
        target = Path(directory) / 'repo'
        shutil.copytree(root, target, ignore=shutil.ignore_patterns('.git', '.mutants', '.zig-cache', 'zig-out', 'zig-pkg'))
        path = target / file
        text = path.read_text()
        assert text.count(old) == 1
        text = text.replace(old, new)
        if name == 'ui_compiler':
            text = text.replace('opts.done(opts.current() and result or { cancelled = true })\n  end)',
                                'opts.done(opts.current() and result or { cancelled = true })\n  end })', 1)
        path.write_text(text)
        status, failed = check(target)
        results.append({'mutant': name, 'failed_tests': failed,
                        'status': 'killed' if status != 0 and failed > 0 else 'survived'})
        print(name, results[-1]['status'], flush=True)
(root / '.mutants/lua/2026-10-05-responsive/outcomes.json').write_text(json.dumps({'results': results}, indent=2) + '\n')
assert all(result['status'] == 'killed' for result in results)
