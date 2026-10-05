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

## Build-aware verification — 2026-10-05

- Zig 0.16.0 build fixtures: standalone fallback (assembly/IR), imported modules,
  generated options, dependency-source selection, file saving, source-cursor
  focus, temporary-prefix cleanup, build failure, and missing artifact.
- LLVM scope identity fixture excludes another file's instruction with the same
  source line number. Build views exclude unrelated assembly locations/functions.
- Run: `GODBOLT_TEST_ZIG="$(mise where zig@0.16.0)/zig" ./scripts/test tests/zig_spec.lua tests/zig_build_spec.lua`.
- Actual `zig-wc`: both build steps work; assembly/IR splits map and focus
  `src/main.zig:26`. Large program globals are streamed past, not loaded into the
  Neovim buffer. Debug mode preserves this wrapper's source correspondence.
- `zig-wc` regression: 219 tests passed; existing user changes left untouched.
- Clang/debug regression: 7 tests passed.
- LSP: Zig build file confirmed clean; Lua checks returned no errors but were
  inconclusive. Lua syntax load check passed.
- Final boundary suite: 16 passed. Seven targeted mutants killed, zero survived;
  report and reproducible runner: `.mutants/lua/2026-10-05-zig-build/`.
  Assessment ran in a user systemd scope with a 4 GiB memory cap and no swap.
- Full Plenary regression: 183 passed, 15 failed; failure names exactly match
  the unchanged-fork baseline. No new failing tests.
- Installed host LazyVim configuration: plugin loaded at startup and both actual
  `<leader>cga`/`<leader>cgi` callbacks opened output focused on `zig-wc` source.
