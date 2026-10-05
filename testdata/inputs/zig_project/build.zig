const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false,
    });
    const helper = b.createModule(.{
        .root_source_file = b.path("src/helper.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addImport("helper", helper);
    const options = b.addOptions();
    options.addOption(i32, "offset", 7);
    root.addOptions("build_options", options);
    const asm_exe = b.addExecutable(.{ .name = "fixture", .root_module = root, .use_llvm = true });
    const ir_exe = b.addExecutable(.{ .name = "fixture", .root_module = root, .use_llvm = true });
    const asm_install = b.addInstallFile(asm_exe.getEmittedAsm(), "godbolt/output.s");
    const ir_install = b.addInstallFile(ir_exe.getEmittedLlvmIr(), "godbolt/output.ll");
    b.step("godbolt-asm", "Assembly").dependOn(&asm_install.step);
    b.step("godbolt-ir", "IR").dependOn(&ir_install.step);
}
