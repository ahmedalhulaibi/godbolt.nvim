# Zig verification

- Runtime: Neovim + Zig 0.17.0, LLVM backend.
- `./scripts/test tests/zig_spec.lua`: 7 passed.
- Plenary directory run: 174 passed, 15 failed. Unchanged HEAD: 167 passed,
  the same 15 failed (pipeline, persistence, output preference, and LTO).
- Full-suite runtime errors also occur on unchanged HEAD. Do not use the
  outer Neovim exit code alone as a suite verdict; inspect each test report.
- Targeted debug-flag regression suite: 7 passed.
- Bounded manual mutation assessment: 5 killed, 0 survived. Each mutant ran
  `tests/zig_spec.lua` in a separate temporary repository copy. Report:
  `.mutants/lua/2026-10-04/outcomes.json`.
- Active LSP check: no error diagnostics returned, but all 5 Lua paths were
  inconclusive. This is not a confirmed clean diagnostic result.

Kill claims: compiler routing, output selection, flag composition, source and
compiler paths with spaces/quotes, debug source mapping, temporary cleanup,
source-file identity, operand-free instructions, foreign-file locations,
and line-zero exclusion.
