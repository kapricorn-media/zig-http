const std = @import("std");
const expect = std.testing.expect;

const libhttp = @import("libhttp.zig");
// const ziget = @import("../deps/ziget/ziget.zig");

test
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const context = try libhttp.start(9000, false, "", &gpa.allocator);
    defer libhttp.stop(context);
    
    try expect(!gpa.deinit());
}

test
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const context = libhttp.start(9000, true, "", &gpa.allocator);
    _ = context catch {
        try expect(!gpa.deinit());
        return;
    };

    try expect(false);
}
