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

## Persistent panes and cache — 2026-10-05

- 24 boundary tests passed: previous 16 plus eight pane/cache tests. Includes
  three-way cursor sync, repeated runs, source identity, stale callbacks,
  unsaved-source handling, active-tab hidden buffers, inactive tabs, input and
  argument hashes, external inputs, LRU eviction, and force refresh.
- Seeded 120-command lifecycle sequence checks pane count, read-only buffers,
  source identity, and rejection of foreign output after every transition.
  This is a bounded model/invariant test, not a Hegel PBT; Hegel has no Lua API.
- Ten targeted mutants killed, zero survivors. Isolated copies; user systemd
  scope, 4 GiB memory cap, no swap. Runner/report:
  `.mutants/lua/2026-10-05-panes/`.
- Full Plenary regression: 191 passed, the same 15 baseline failures, no test
  errors. Run with `GODBOLT_TEST_ZIG` set to Zig 0.16.0.
- Actual host LazyVim: local checkout loaded at startup; real assembly/IR keys
  created three windows. Switching `main.zig` → `whitespace.zig` kept both pane
  buffer/window IDs. Returning to `main.zig` and invoking both keys caused no
  additional builds (four total). Names/read-only flags and default code-action
  configuration verified. Public plugin pin unchanged; local checkout override.
- Lua syntax load passed. Active LSP probe: no errors reported, six paths
  inconclusive; this is not a confirmed clean diagnostic result.

## Nonblocking pane builds — 2026-10-05

- Reproduced synchronous input fingerprinting in `bf87b58`. Green fix moves
  hashing, standalone compilation, and large artifact scans into persistent,
  isolated headless workers. UI validation is asynchronous and coalesced;
  changed-source results and errors are discarded.
- 26 boundary tests passed, including slow-tool assembly/IR fixtures: trigger
  returns within 150 ms, normal-mode input executes while work is pending,
  timer callbacks continue, and no UI stall exceeds 200 ms.
- Actual `zig-wc` cold smoke, including its 196 MiB corpus: trigger 1.83 ms;
  708 UI timer callbacks; largest timer gap 22.15 ms; three windows after both
  assembly and IR complete. Existing user files left unchanged.
- Full Plenary: 193 passed, same 15 baseline failures, no test errors.
- Two responsiveness mutants and ten existing pane/cache mutants killed.
  Isolated copies, 4 GiB user systemd scopes, no swap. Reports:
  `.mutants/lua/2026-10-05-responsive/`; pane reassessment uses
  `GODBOLT_MUTATION_REPORT=.mutants/lua/2026-10-05-responsive/pane-outcomes.json`.
- Lua syntax passed; active LSP reported no errors, six paths inconclusive.

## Selection gutters — 2026-10-05

- Selected assembly/IR instructions have bright `▶` extmark signs, fixed
  one-column native gutters, and no additional background highlighting.
  Source buffers keep their existing gutter. Theme changes restore the sign
  group; users can override `GodboltSelectionSign`.
- 27 boundary tests passed. New table checks all mapped rows, selection changes,
  unmapped rows, source focus, non-Zig switching, and theme recovery. Native
  status-column evaluation verifies actual inactive-pane glyph rendering.
- Full Plenary: 194 passed, same 15 baseline failures, zero test errors.
- Four targeted mutants killed: missing signs, hidden gutter, missing native
  gutter, stale selection. Reports: `.mutants/lua/2026-10-05-gutter/`;
  isolated copies in 4 GiB no-swap systemd scopes.
- Lua syntax passed. Active LSP reported no errors; three paths inconclusive.

## Assembly language server — 2026-10-06

- Read-only assembly panes have synchronized temporary `.s` files and file URIs;
  IR remains virtual. Paths are unique across same-basename source switches.
  Pane/window, buffer, tab, and editor teardown delete temporary files.
- Dedicated `asm_lsp` clients use source-project roots and existing Neovim
  configuration. Closing clients are excluded from reuse. Pull diagnostics are
  disabled and push diagnostics ignored for excerpts; normal clients unaffected.
- 29 boundary tests passed with Zig 0.16.0 and asm-lsp 0.10.1. Real hover passes
  before and after source switches; lifecycle test checks disk/buffer equality
  and cleanup. Run with `GODBOLT_TEST_ASM_LSP=/path/to/asm-lsp` to include the
  real-server boundary in `tests/panes_spec.lua`.
- Full Plenary: 196 passed, same 15 baseline failures, zero test errors. Lua
  syntax passed. Active LSP probe: no errors, four paths inconclusive.
- Four targeted mutants killed: contents, cleanup, file URI, and source-project
  root. Reports: `.mutants/lua/2026-10-06-assembly-lsp/`; isolated copies in
  4 GiB no-swap systemd scopes.
