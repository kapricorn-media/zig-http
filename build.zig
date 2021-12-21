const std = @import("std");

const zig_bearssl = @import("deps/zig-bearssl/src/lib.zig");
// const zig_openssl_build = @import("deps/zig-openssl/build.zig");

pub fn build(b: *std.build.Builder) void
{
    // const target = std.zig.CrossTarget {
    //     .cpu_arch = null,
    //     .os_tag = .linux,
    //     .abi = .gnu,
    //     .glibc_version = .{
    //         .major=2,
    //         .minor=28
    //     }
    // };
    // const mode = b.standardReleaseOptions();

    // const tests = b.addTest("test/test.zig");
    // tests.setTarget(target);
    // tests.setBuildMode(mode);
    // addLib(tests, target, ".");
    // zig_openssl_build.addLib(tests, target, "deps/zig-openssl") catch unreachable;
    // tests.linkLibC();

    // const runTests = b.step("test", "Run library tests");
    // runTests.dependOn(&tests.step);

    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const testClient = b.addTest("test/test_client.zig");
    testClient.setBuildMode(mode);
    testClient.setTarget(target);
    addLibClient(testClient, ".");
    zig_bearssl.linkBearSSL("deps/zig-bearssl", testClient, target);
    testClient.addIncludeDir("src");
    testClient.addCSourceFile("src/macos_certs.m", &[_][]const u8{
        "-Wall",
        "-Werror",
        "-Wextra",
    });
    testClient.linkFramework("Foundation");
    testClient.linkFramework("Security");
    // testClient.linkLibC();

    const runTests = b.step("test", "Run library tests");
    runTests.dependOn(&testClient.step);
}

pub fn addLibClient(step: *std.build.LibExeObjStep, comptime dir: []const u8) void
{
    step.addPackagePath("http-client", dir ++ "/src/client.zig");
}

// pub fn addLib(step: *std.build.LibExeObjStep, target: std.zig.CrossTarget, comptime dir: []const u8) void
// {
//     step.addPackagePath("http-client", dir ++ "/src/client.zig");
//     step.addPackagePath("http-server", dir ++ "/src/server.zig");
//     const cFlags = &[_][]const u8 {
//         "-Wall", "-Wextra", "-Werror",
//         "-Wno-deprecated-declarations",
//         "-Wno-implicit-function-declaration",
//         "-Wno-unused-function",
//         "-DNO_SSL_DL=1",
//     };
//     step.addIncludeDir(dir ++ "/src");
//     step.addCSourceFiles(&[_][]const u8 {
//         dir ++ "/src/civetweb.c",
//     }, cFlags);

//     zig_openssl_build.addLib(step, target, dir ++ "/deps/zig-openssl") catch unreachable;
// }
