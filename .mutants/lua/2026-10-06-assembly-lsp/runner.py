import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

root = Path.cwd()
assert os.environ.get('GODBOLT_TEST_ASM_LSP')
mutants = [
    ('file_contents', 'vim.fn.writefile(lines, file)', 'vim.fn.writefile({}, file)'),
    ('file_cleanup', "if p.temp_dir then vim.fn.delete(p.temp_dir, 'rf') end", 'if false then vim.fn.delete(p.temp_dir, \'rf\') end'),
    ('file_uri', 'vim.api.nvim_buf_set_name(p.buf, file)', "vim.api.nvim_buf_set_name(p.buf, 'godbolt://' .. file)"),
    ('project_root', "'asm_lsp', root, cfg.cmd_cwd or root", "'asm_lsp', p.temp_dir, cfg.cmd_cwd or root"),
]

def check(directory):
    result = subprocess.run(['./scripts/test', 'tests/panes_spec.lua'], cwd=directory,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
    total = re.search(r'Total:\s+(\d+)', result.stdout)
    failed = re.search(r'Failed:\s+(\d+)', result.stdout)
    assert total and int(total[1]) == 11 and failed, result.stdout[-3000:]
    if directory == root and (result.returncode or int(failed[1])):
        print(result.stdout, flush=True)
    return result.returncode, int(failed[1])

assert check(root) == (0, 0)
results = []
for name, old, new in mutants:
    with tempfile.TemporaryDirectory(prefix='godbolt-assembly-mutant-') as directory:
        target = Path(directory) / 'repo'
        shutil.copytree(root, target, ignore=shutil.ignore_patterns('.git', '.mutants', '.zig-cache', 'zig-out', 'zig-pkg'))
        path = target / 'lua/godbolt/assembly_buffer.lua'
        text = path.read_text()
        assert text.count(old) == 1
        path.write_text(text.replace(old, new))
        status, failed = check(target)
        results.append({'mutant': name, 'failed_tests': failed,
                        'status': 'killed' if status != 0 and failed > 0 else 'survived'})
        print(name, results[-1]['status'], flush=True)
(root / '.mutants/lua/2026-10-06-assembly-lsp/outcomes.json').write_text(json.dumps({'results': results}, indent=2) + '\n')
assert all(result['status'] == 'killed' for result in results)
