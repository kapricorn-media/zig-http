const std = @import("std");
const expect = std.testing.expect;

const libhttp = @import("libhttp.zig");
// const ziget = @import("../deps/ziget/ziget.zig");

test "success: port 9000, no SSL"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const context = try libhttp.start(9000, false, "", &gpa.allocator);
    defer libhttp.stop(context);
    
    try expect(!gpa.deinit());
}

fn handlerNullData(connection: *libhttp.mg_connection, data: ?*c_void) !void
{
    _ = connection;
    try expect(data == null);
}

test "success: port 9000, no SSL, request handler"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const context = try libhttp.start(9000, false, "", &gpa.allocator);
    defer libhttp.stop(context);

    libhttp.setRequestHandler(context, "/", handlerNullData, null);
    
    try expect(!gpa.deinit());
}

test "fail: port 9000, SSL, no cert"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const context = libhttp.start(9000, true, "", &gpa.allocator);
    _ = context catch {
        try expect(!gpa.deinit());
        return;
    };

    try expect(false);
}
