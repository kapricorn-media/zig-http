const std = @import("std");

pub fn build(b: *std.build.Builder) void
{
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("libhttp", null);
    lib.setTarget(target);
    lib.setBuildMode(mode);
    lib.linkLibC();
    lib.install();

    addLib(lib, ".");
}

pub fn addLib(step: *std.build.LibExeObjStep, comptime dir: []const u8) void
{
    const cFlags = &[_][]const u8 {
    };
    step.addIncludeDir(dir ++ "/include");
    step.addCSourceFiles(&[_][]const u8 {
        dir ++ "/src/civetweb.c",
    }, cFlags);
}
