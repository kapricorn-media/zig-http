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
    // const lib = b.addStaticLibrary("libhttp", null);
    // lib.setTarget(target);
    // lib.setBuildMode(mode);
    // addLib(lib, ".");
    // lib.linkLibC();
    // lib.install();

    const pkgSsl = std.build.Pkg {
        .name = "ssl",
        .path = std.build.FileSource.relative("deps/ziget/openssl/ssl.zig"),
        .dependencies = null,
    };
    const pkgZiget = std.build.Pkg {
        .name = "ziget",
        .path = std.build.FileSource.relative("deps/ziget/ziget.zig"),
        .dependencies = &[_]std.build.Pkg {
            pkgSsl
        },
    };

    const tests = b.addTest("src/test.zig");
    tests.setTarget(target);
    tests.setBuildMode(mode);
    addLib(tests, ".");
    zig_openssl_build.addLib(tests, target, "deps/zig-openssl") catch unreachable;
    tests.addPackage(pkgZiget);
    tests.linkLibC();

    const runTests = b.step("test", "Run library tests");
    runTests.dependOn(&tests.step);
}

pub fn addLib(step: *std.build.LibExeObjStep, comptime dir: []const u8) void
{
    step.addPackagePath("libhttp", "src/libhttp.zig");
    const cFlags = &[_][]const u8 {
    };
    step.addIncludeDir(dir ++ "/include");
    step.addCSourceFiles(&[_][]const u8 {
        dir ++ "/src/civetweb.c",
    }, cFlags);
}
