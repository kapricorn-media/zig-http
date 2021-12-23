const builtin = @import("builtin");
const std = @import("std");

const zig_bearssl = @import("deps/zig-bearssl/src/lib.zig");

pub fn build(b: *std.build.Builder) void
{
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const testClient = b.addTest("test/test_client.zig");
    testClient.setBuildMode(mode);
    testClient.setTarget(target);
    addLibClient(testClient, target, ".");
    zig_bearssl.linkBearSSL("deps/zig-bearssl", testClient, target);
    testClient.linkLibC();

    const testServer = b.addTest("test/test_server.zig");
    testServer.setBuildMode(mode);
    testServer.setTarget(target);
    addLibServer(testServer, target, ".");
    zig_bearssl.linkBearSSL("deps/zig-bearssl", testServer, target);
    testServer.linkLibC();

    const testBoth = b.addTest("test/test_both.zig");
    testBoth.setBuildMode(mode);
    testBoth.setTarget(target);
    addLibCommon(testBoth, target, ".");
    addLibClient(testBoth, target, ".");
    addLibServer(testBoth, target, ".");
    zig_bearssl.linkBearSSL("deps/zig-bearssl", testBoth, target);
    testBoth.linkLibC();

    const runTests = b.step("test", "Run library tests");
    // runTests.dependOn(&testClient.step);
    // runTests.dependOn(&testServer.step);
    runTests.dependOn(&testBoth.step);
}

pub fn addLibCommon(
    step: *std.build.LibExeObjStep,
    target: std.zig.CrossTarget,
    comptime dir: []const u8) void
{
    _ = target;
    const pkg = getPackageCommon(dir);
    step.addPackage(pkg);
}

pub fn addLibClient(
    step: *std.build.LibExeObjStep,
    target: std.zig.CrossTarget,
    comptime dir: []const u8) void
{
    const pkg = std.build.Pkg {
        .name = "http-client",
        .path = .{
            .path = dir ++ "/src/client.zig",
        },
        .dependencies = &[_]std.build.Pkg {
            getPackageCommon(dir)
        },
    };
    step.addPackage(pkg);
    const targetOs = if (target.os_tag) |tag| tag else builtin.os.tag;
    if (targetOs == .macos) {
        step.addIncludeDir("src");
        step.addCSourceFile("src/macos_certs.m", &[_][]const u8{
            "-Wall",
            "-Werror",
            "-Wextra",
        });
        step.linkFramework("Foundation");
        step.linkFramework("Security");
    }
}

pub fn addLibServer(
    step: *std.build.LibExeObjStep,
    target: std.zig.CrossTarget,
    comptime dir: []const u8) void
{
    _ = target;
    const pkg = std.build.Pkg {
        .name = "http-server",
        .path = .{
            .path = dir ++ "/src/server.zig",
        },
        .dependencies = &[_]std.build.Pkg {
            getPackageCommon(dir)
        },
    };
    step.addPackage(pkg);
}

fn getPackageCommon(comptime dir: []const u8) std.build.Pkg
{
    return .{
        .name = "http-common",
        .path = .{
            .path = dir ++ "/src/common.zig",
        },
        .dependencies = null,
    };
}
