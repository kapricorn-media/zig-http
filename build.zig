const std = @import("std");

const zig_openssl_build = @import("deps/zig-openssl/build.zig");

pub fn build(b: *std.build.Builder) void
{
    const target = std.zig.CrossTarget {
        .cpu_arch = null,
        .os_tag = .linux,
        .abi = .gnu,
        .glibc_version = .{
            .major=2,
            .minor=28
        }
    };
    const mode = b.standardReleaseOptions();

    const tests = b.addTest("src/test.zig");
    tests.setTarget(target);
    tests.setBuildMode(mode);
    addLib(tests, ".");
    zig_openssl_build.addLib(tests, target, "deps/zig-openssl") catch unreachable;
    tests.linkLibC();

    const runTests = b.step("test", "Run library tests");
    runTests.dependOn(&tests.step);
}

pub fn addLib(step: *std.build.LibExeObjStep, comptime dir: []const u8) void
{
    step.addPackagePath("http-client", "src/client.zig");
    step.addPackagePath("http-server", "src/server.zig");
    const cFlags = &[_][]const u8 {
    };
    step.addIncludeDir(dir ++ "/src");
    step.addCSourceFiles(&[_][]const u8 {
        dir ++ "/src/civetweb.c",
    }, cFlags);
}
