const std = @import("std");
const ssl = @import("ssl");
const ziget = @import("ziget");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const libhttp = @import("libhttp.zig");

const cc = @import("client.zig");

const TEST_PORT = 19191;
const TEST_HOSTNAME = "127.0.0.1";

// server tests

test "server, no SSL"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const context = try libhttp.start(TEST_PORT, false, "", &gpa.allocator);
    defer libhttp.stop(context);
    
    try expect(!gpa.deinit()); // TODO ideally this should be defer'd at the start
}

fn handlerNullData(connection: *libhttp.mg_connection, data: ?*c_void) !void
{
    _ = connection;
    try expectEqual(data, null);
}

test "server, no SSL, request handler"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const context = try libhttp.start(TEST_PORT, false, "", &gpa.allocator);
    defer libhttp.stop(context);

    libhttp.setRequestHandler(context, "/", handlerNullData, null);
    
    try expect(!gpa.deinit());
}

test "server, SSL, no cert, FAIL"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const context = libhttp.start(TEST_PORT, true, "", &gpa.allocator);
    _ = context catch {
        try expect(!gpa.deinit());
        return;
    };

    try expect(false);
}

// server+client tests

fn checkHeaders(actual: []const cc.Header, expected: []const cc.Header) !void
{
    if (actual.len != expected.len) {
        std.log.err("header len actual {}, expected {}", .{actual.len, expected.len});
        return error.lenMismatch;
    }

    for (actual) |_, i| {
        try expectEqualSlices(u8, actual[i].name, expected[i].name);
        try expectEqualSlices(u8, actual[i].value, expected[i].value);
    }
}

fn handlerNoResponse(connection: *libhttp.mg_connection, data: ?*c_void) !void
{
    _ = connection;
    try expectEqual(data, null);
}

test "server+client, get /, no response"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const context = try libhttp.start(TEST_PORT, false, "", &gpa.allocator);
    defer libhttp.stop(context);
    libhttp.setRequestHandler(context, "/", handlerNoResponse, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: cc.Response = undefined;
    cc.get(false, TEST_PORT, TEST_HOSTNAME, "/", &gpa.allocator, &responseData, &response) catch {
        try expect(!gpa.deinit());
        return;
    };
    
    try expect(false);
}

fn handlerOk(connection: *libhttp.mg_connection, data: ?*c_void) !void
{
    try expectEqual(data, null);
    try libhttp.writeHttpCode(connection, ._200);
    try libhttp.writeHttpEndHeader(connection);
}

test "server+client, get /, 200"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const context = try libhttp.start(TEST_PORT, false, "", &gpa.allocator);
    defer libhttp.stop(context);
    libhttp.setRequestHandler(context, "/", handlerOk, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: cc.Response = undefined;
    try cc.get(false, TEST_PORT, TEST_HOSTNAME, "/", &gpa.allocator, &responseData, &response);
    try expectEqual(response.code, 200);
    try expectEqualSlices(u8, response.message, "OK");
    try expectEqual(response.body.len, 0);
}

fn handlerInternalError(connection: *libhttp.mg_connection, data: ?*c_void) !void
{
    try expectEqual(data, null);
    try libhttp.writeHttpCode(connection, ._500);
    try libhttp.writeHttpEndHeader(connection);
}

test "server+client, get /, 500"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const context = try libhttp.start(TEST_PORT, false, "", &gpa.allocator);
    defer libhttp.stop(context);
    libhttp.setRequestHandler(context, "/", handlerInternalError, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: cc.Response = undefined;
    try cc.get(false, TEST_PORT, TEST_HOSTNAME, "/", &gpa.allocator, &responseData, &response);
    try expectEqual(response.code, 500);
    try expectEqualSlices(u8, response.message, "Internal Server Error");
    try expectEqual(response.body.len, 0);
}

fn handlerHelloWorld(connection: *libhttp.mg_connection, data: ?*c_void) !void
{
    try expectEqual(data, null);
    try libhttp.writeHttpCode(connection, ._200);
    try libhttp.writeHttpContentType(connection, .TextPlain);
    try libhttp.writeHttpEndHeader(connection);
    const str = "Hello, world!";
    try expectEqual(libhttp.mg_write(connection, &str[0], str.len), str.len);
}

test "server+client, get /, 200, return data"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const context = try libhttp.start(TEST_PORT, false, "", &gpa.allocator);
    defer libhttp.stop(context);
    libhttp.setRequestHandler(context, "/", handlerHelloWorld, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: cc.Response = undefined;
    try cc.get(false, TEST_PORT, TEST_HOSTNAME, "/", &gpa.allocator, &responseData, &response);
    try expectEqual(response.code, 200);
    try expectEqualSlices(u8, response.message, "OK");
    const expectedHeaders = [_]cc.Header {
        .{
            .name = "Content-Type",
            .value = "text/plain",
        },
    };
    try checkHeaders(response.headers[0..response.numHeaders], &expectedHeaders);
    try expectEqualSlices(u8, response.body, "Hello, world!");
}

test "server+client, get /custom_uri, 200, return data"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const context = try libhttp.start(TEST_PORT, false, "", &gpa.allocator);
    defer libhttp.stop(context);
    libhttp.setRequestHandler(context, "/custom_uri", handlerHelloWorld, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: cc.Response = undefined;
    try cc.get(false, TEST_PORT, TEST_HOSTNAME, "/custom_uri", &gpa.allocator, &responseData, &response);
    try expectEqual(response.code, 200);
    try expectEqualSlices(u8, response.message, "OK");
    const expectedHeaders = [_]cc.Header {
        .{
            .name = "Content-Type",
            .value = "text/plain",
        },
    };
    try checkHeaders(response.headers[0..response.numHeaders], &expectedHeaders);
    try expectEqualSlices(u8, response.body, "Hello, world!");
}
