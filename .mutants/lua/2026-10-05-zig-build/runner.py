import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

root = Path.cwd()
assert Path(os.environ['GODBOLT_TEST_ZIG']).is_file()
mutants = [
    ('project_discovery', 'lua/godbolt/zig_build.lua', 'if not build_file then', 'if true then'),
    ('build_step', 'lua/godbolt/zig_build.lua', "output_type == 'llvm' and 'godbolt-ir' or 'godbolt-asm'", "output_type == 'llvm' and 'godbolt-asm' or 'godbolt-ir'"),
    ('temporary_cleanup', 'lua/godbolt/zig_build.lua', "vim.fn.delete(prefix, 'rf')\n      if result.code", "-- omit cleanup\n      if result.code"),
    ('source_scope', 'lua/godbolt/parsers/llvm_ir.lua', '(not source_file or scope_file(scope) == source_file)', 'true'),
    ('initial_focus', 'lua/godbolt.lua', 'if source_line then line_map.focus_source_line(source_line) end', '-- omit initial focus'),
    ('assembly_source_filter', 'lua/godbolt/zig_output.lua', 'selected_ids[id] == true and tonumber(source_line) > 0', 'tonumber(source_line) > 0'),
    ('llvm_source_filter', 'lua/godbolt/zig_output.lua', 'if selected then\n          vim.list_extend(output, func)', 'if true then\n          vim.list_extend(output, func)'),
]
command = ['nvim', '-l', 'tests/minit.lua', 'tests/zig_spec.lua', 'tests/zig_build_spec.lua']

def check(directory):
    run = subprocess.run(command, cwd=directory, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
    total = re.search(r'Total:\s+(\d+)', run.stdout)
    failed = re.search(r'Failed:\s+(\d+)', run.stdout)
    assert total and int(total[1]) == 16 and failed, run.stdout[-2000:]
    return run.returncode, int(failed[1])

assert check(root) == (0, 0), 'Baseline must pass before mutation'
results = []
for name, file, old, new in mutants:
    with tempfile.TemporaryDirectory(prefix='godbolt-build-mutant-') as directory:
        target = Path(directory) / 'repo'
        shutil.copytree(root, target, ignore=shutil.ignore_patterns('.git', '.mutants', '.zig-cache', 'zig-out', 'zig-pkg'))
        path = target / file
        text = path.read_text()
        assert text.count(old) == 1, name
        path.write_text(text.replace(old, new))
        status, failed = check(target)
        result = {'mutant': name, 'file': file, 'exit_code': status, 'failed_tests': failed,
                  'status': 'killed' if status != 0 and failed > 0 else 'survived'}
        results.append(result)
        print(name, result['status'], flush=True)
report = root / '.mutants/lua' / (datetime.date.today().isoformat() + '-zig-build')
report.mkdir(parents=True, exist_ok=True)
(report / 'outcomes.json').write_text(json.dumps({'method': 'bounded manual mutation: one edit per temporary copy, 16 boundary tests',
    'compiler': subprocess.check_output([os.environ['GODBOLT_TEST_ZIG'], 'version'], text=True).strip(), 'results': results}, indent=2) + '\n')
shutil.copyfile(__file__, report / 'runner.py')
assert all(result['status'] == 'killed' for result in results)
