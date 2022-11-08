const builtin = @import("builtin");
const std = @import("std");

const zig_bearssl_build = @import("deps/zig-bearssl/build.zig");

pub fn build(b: *std.build.Builder) void
{
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const sampleClient = b.addExecutable("sample_client", "test/sample_client.zig");
    sampleClient.setBuildMode(mode);
    sampleClient.setTarget(target);
    addLibCommon(sampleClient, target, ".");
    addLibClient(sampleClient, target, ".");
    zig_bearssl_build.addLib(sampleClient, target, "deps/zig-bearssl");
    sampleClient.linkLibC();
    sampleClient.install();

    const sampleServer = b.addExecutable("sample_server", "test/sample_server.zig");
    sampleServer.setBuildMode(mode);
    sampleServer.setTarget(target);
    addLibCommon(sampleServer, target, ".");
    addLibServer(sampleServer, target, ".");
    zig_bearssl_build.addLib(sampleServer, target, "deps/zig-bearssl");
    sampleServer.linkLibC();
    sampleServer.install();

    const testClient = b.addTest("test/test_client.zig");
    testClient.setBuildMode(mode);
    testClient.setTarget(target);
    addLibCommon(testClient, target, ".");
    addLibClient(testClient, target, ".");
    zig_bearssl_build.addLib(testClient, target, "deps/zig-bearssl");
    testClient.linkLibC();

    const testCommon = b.addTest("test/test_common.zig");
    testCommon.setBuildMode(mode);
    testCommon.setTarget(target);
    addLibCommon(testCommon, target, ".");
    testCommon.linkLibC();

    const testServer = b.addTest("test/test_server.zig");
    testServer.setBuildMode(mode);
    testServer.setTarget(target);
    addLibCommon(testServer, target, ".");
    addLibServer(testServer, target, ".");
    zig_bearssl_build.addLib(testServer, target, "deps/zig-bearssl");
    testServer.linkLibC();

    const testBoth = b.addTest("test/test_both.zig");
    testBoth.setBuildMode(mode);
    testBoth.setTarget(target);
    addLibCommon(testBoth, target, ".");
    addLibClient(testBoth, target, ".");
    addLibServer(testBoth, target, ".");
    zig_bearssl_build.addLib(testBoth, target, "deps/zig-bearssl");
    testBoth.linkLibC();

    const runTests = b.step("test", "Run library tests");
    runTests.dependOn(&testClient.step);
    runTests.dependOn(&testCommon.step);
    // runTests.dependOn(&testServer.step);
    runTests.dependOn(&testBoth.step);
}

pub fn addLibCommon(
    step: *std.build.LibExeObjStep,
    target: std.zig.CrossTarget,
    comptime dir: []const u8) void
{
    _ = target;
    const pkg = getPkgCommon(dir);
    step.addPackage(pkg);
}

pub fn addLibClient(
    step: *std.build.LibExeObjStep,
    target: std.zig.CrossTarget,
    comptime dir: []const u8) void
{
    const pkg = std.build.Pkg {
        .name = "http-client",
        .source = .{
            .path = dir ++ "/src/client.zig",
        },
        .dependencies = &[_]std.build.Pkg {
            getPkgCommon(dir),
            zig_bearssl_build.getPkg(dir ++ "/deps/zig-bearssl"),
        },
    };
    step.addPackage(pkg);
    const targetOs = if (target.os_tag) |tag| tag else builtin.os.tag;
    if (targetOs == .macos) {
        step.addIncludePath(dir ++ "/src");
        step.addCSourceFile(dir ++ "/src/macos_certs.m", &[_][]const u8{
            "-Wall",
            "-Werror",
            "-Wextra",
            "-Wno-deprecated-declarations",
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
        .source = .{
            .path = dir ++ "/src/server.zig",
        },
        .dependencies = &[_]std.build.Pkg {
            getPkgCommon(dir),
            zig_bearssl_build.getPkg(dir ++ "/deps/zig-bearssl"),
        },
    };
    step.addPackage(pkg);
}

fn getPkgCommon(comptime dir: []const u8) std.build.Pkg
{
    return .{
        .name = "http-common",
        .source = .{
            .path = dir ++ "/src/common.zig",
        },
        .dependencies = null,
    };
}
