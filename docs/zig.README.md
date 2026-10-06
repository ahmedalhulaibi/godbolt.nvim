# Zig project setup

Godbolt.nvim uses your **local Zig compiler**, not the hosted Compiler Explorer
API. The persistent pane API builds the nearest ancestor `build.zig`. Each
project must define the two steps below; a normal `zig build` is not sufficient.

## 1. Add build steps

Minimal executable project (`main.zig` beside `build.zig`), using the Zig
0.16/0.17 build API:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false,
    });

    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const assembly = b.addExecutable(.{
        .name = "app-godbolt-asm",
        .root_module = root_module,
        .use_llvm = true,
    });
    const install_asm = b.addInstallFile(assembly.getEmittedAsm(), "godbolt/output.s");
    b.step("godbolt-asm", "Emit assembly for Neovim").dependOn(&install_asm.step);

    const ir = b.addExecutable(.{
        .name = "app-godbolt-ir",
        .root_module = root_module,
        .use_llvm = true,
    });
    const install_ir = b.addInstallFile(ir.getEmittedLlvmIr(), "godbolt/output.ll");
    b.step("godbolt-ir", "Emit LLVM IR for Neovim").dependOn(&install_ir.step);
}
```

For an existing project, **keep its module graph**. Attach these steps to its
existing root module (for example, `exe.root_module`), preserving imports,
generated options, dependencies, target, optimization, and linking settings.
Adapt the artifact type to your project; do not copy compiler flags into Lua.
Keep debug information enabled (`strip = false`). If your normal build strips
debug information, construct an inspection module from the same module options
and imports with stripping disabled.

The contract is fixed:

| Build step | Installed artifact, relative to `--prefix` |
| --- | --- |
| `godbolt-asm` | `godbolt/output.s` |
| `godbolt-ir` | `godbolt/output.ll` |

Use install steps, not hard-coded `zig-out` paths. The plugin supplies a temporary
`--prefix`, reads the artifacts, then removes that directory.

## 2. Verify outside Neovim

Run from the directory containing `build.zig`:

```sh
zig version
zig build -l
zig build godbolt-asm -Doptimize=Debug
zig build godbolt-ir -Doptimize=Debug
ls -lh zig-out/godbolt/output.s zig-out/godbolt/output.ll
```

Use the Zig version required by the project. Start with `Debug`: optimized code
can remove or inline source lines, making cursor mappings incomplete.

## 3. Configure Neovim

Example lazy.nvim/LazyVim plugin specification:

```lua
return {
  {
    'ahmedalhulaibi/godbolt.nvim',
    main = 'godbolt',
    opts = {
      zig = 'zig', -- Or an absolute path to the project's compiler.
      zig_build_args = { '-Doptimize=Debug' },
      line_mapping = { enabled = true, auto_scroll = true },
    },
    keys = {
      { '<leader>cga', function() require('godbolt').godbolt_zig('asm') end, desc = 'Zig assembly' },
      { '<leader>cgi', function() require('godbolt').godbolt_zig('llvm') end, desc = 'Zig LLVM IR' },
      { '<leader>cgr', function() require('godbolt.panes').refresh() end, desc = 'Refresh Zig panes' },
      { '<leader>cgq', function() require('godbolt.panes').close() end, desc = 'Close Zig panes' },
    },
  },
}
```

With Space as leader, use **Space c g a** and **Space c g i** in a saved `.zig`
file. These preserve **Space c a** for code actions. Cursor movement synchronizes
source, assembly, and IR; bright `▶` gutter markers identify selected output
lines even in inactive panes. Output buffers are read-only.

Project arguments go in `zig_build_args`. Override them per source buffer with
`vim.b.godbolt_build_args = { '-Doptimize=ReleaseFast' }`; this replaces, rather
than extends, the global list. `zig_args` applies only to standalone compilation.
Do not supply `--prefix`; the plugin owns it.

## Troubleshooting

- **“Project build failed; no standalone fallback”**: inspect the Zig error
  below this message. `no such step: godbolt-asm` or `godbolt-ir` means the steps
  above are missing. Run the failing step directly; fix build errors or compiler
  version mismatches before retrying. A project build failure never falls back
  to standalone compilation, which could omit its dependencies and settings.
- **Unexpected project**: selection uses the nearest ancestor `build.zig`, even
  outside the source directory. Standalone `zig build-obj` is used only when no
  ancestor has `build.zig`. Raw `:Godbolt` is a separate one-shot workflow; use
  the pane API/keymaps for project builds.
- **Artifact missing**: check the exact installed paths in the table and verify
  `zig build godbolt-asm --prefix /tmp/my-zig-inspection` writes
  `/tmp/my-zig-inspection/godbolt/output.s` (likewise for IR).
- **No emitted code or missing markers**: the source must be reachable from the
  selected root module. Unused functions, stripped debug information, inlining,
  and optimization can remove mappings. LLVM output is a source-focused excerpt,
  not a complete compilable module.
- **Unsaved source**: save it before compiling. Switching files does not save
  modified buffers automatically; unsaved/non-Zig source clears stale output.
- **External or ignored build inputs**: declare files/directories in
  `panes.cache_paths`. Use the refresh key to bypass cached results after changes
  to undeclared inputs or environment-dependent build logic. Hidden panes defer
  compilation until shown; hashing, compilation, and scanning run off the UI
  thread.

No `compile_commands.json` is required for Zig.
