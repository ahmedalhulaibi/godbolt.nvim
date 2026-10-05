const std = @import("std");
pub fn build(b: *std.Build) void {
    b.step("godbolt-asm", "Succeed without emitting an artifact").dependOn(b.getInstallStep());
}
