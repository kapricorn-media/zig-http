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

fn expectAnyError(result: anytype) !void
{
    if (result) |payload| {
        std.debug.print("expected error, found {}\n", .{payload});
        return error.TestNoError;
    } else |err| {
        const typeInfo = @typeInfo(@TypeOf(err));
        switch (typeInfo) {
            .ErrorSet => {},
            else => {
                std.log.err("expected error set type, found {}", .{typeInfo});
                return error.TestNoError;
            },
        }
    }
}

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
    try expectEqual(@as(?*c_void, null), data);
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
    try expectAnyError(context);
}

// server+client tests

fn expectHeaders(expected: []const cc.Header, actual: []const cc.Header) !void
{
    if (actual.len != expected.len) {
        std.log.err("header len actual {}, expected {}", .{actual.len, expected.len});
        return error.lenMismatch;
    }

    for (actual) |_, i| {
        try expectEqualSlices(u8, expected[i].name, actual[i].name);
        try expectEqualSlices(u8, expected[i].value, actual[i].value);
    }
}

fn handlerNoResponse(connection: *libhttp.mg_connection, data: ?*c_void) !void
{
    _ = connection;
    try expectEqual(@as(?*c_void, null), data);
}

test "server+client, get /, no response"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const context = try libhttp.start(TEST_PORT, false, "", &gpa.allocator);
    defer libhttp.stop(context);
    libhttp.setRequestHandler(context, "/", handlerNoResponse, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: cc.Response = undefined;
    try expectAnyError(cc.get(false, TEST_PORT, TEST_HOSTNAME, "/", &gpa.allocator, &responseData, &response));
}

fn handlerOk(connection: *libhttp.mg_connection, data: ?*c_void) !void
{
    try expectEqual(@as(?*c_void, null), data);
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
    try expectEqual(@as(u32, 200), response.code);
    try expectEqualSlices(u8, "OK", response.message);
    try expectEqual(@as(usize, 0), response.body.len);
}

fn handlerInternalError(connection: *libhttp.mg_connection, data: ?*c_void) !void
{
    try expectEqual(@as(?*c_void, null), data);
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
    try expectEqual(@as(u32, 500), response.code);
    try expectEqualSlices(u8, "Internal Server Error", response.message);
    try expectEqual(@as(usize, 0), response.body.len);
}

fn handlerHelloWorld(connection: *libhttp.mg_connection, data: ?*c_void) !void
{
    try expectEqual(@as(?*c_void, null), data);
    try libhttp.writeHttpCode(connection, ._200);
    try libhttp.writeHttpContentType(connection, .TextPlain);
    try libhttp.writeHttpEndHeader(connection);
    const str = "Hello, world!";
    try expectEqual(@as(c_int, str.len), libhttp.mg_write(connection, &str[0], str.len));
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
    try expectEqual(@as(u32, 200), response.code);
    try expectEqualSlices(u8, "OK", response.message);
    const expectedHeaders = [_]cc.Header {
        .{
            .name = "Content-Type",
            .value = "text/plain",
        },
    };
    try expectHeaders(&expectedHeaders, response.headers[0..response.numHeaders]);
    try expectEqualSlices(u8, "Hello, world!", response.body);
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
    try expectEqual(@as(u32, 200), response.code);
    try expectEqualSlices(u8, "OK", response.message);
    const expectedHeaders = [_]cc.Header {
        .{
            .name = "Content-Type",
            .value = "text/plain",
        },
    };
    try expectHeaders(&expectedHeaders, response.headers[0..response.numHeaders]);
    try expectEqualSlices(u8, "Hello, world!", response.body);
}

test "server+client, get /, serve /custom_uri"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const context = try libhttp.start(TEST_PORT, false, "", &gpa.allocator);
    defer libhttp.stop(context);
    libhttp.setRequestHandler(context, "/custom_uri", handlerHelloWorld, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: cc.Response = undefined;
    try cc.get(false, TEST_PORT, TEST_HOSTNAME, "/", &gpa.allocator, &responseData, &response);
    try expectEqual(@as(u32, 404), response.code);
    try expectEqualSlices(u8, "Not Found", response.message);
}

test "server+client, get /custom_uri, serve /"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const context = try libhttp.start(TEST_PORT, false, "", &gpa.allocator);
    defer libhttp.stop(context);
    libhttp.setRequestHandler(context, "/", handlerHelloWorld, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: cc.Response = undefined;
    try cc.get(false, TEST_PORT, TEST_HOSTNAME, "/custom_uri", &gpa.allocator, &responseData, &response);
    try expectEqual(@as(u32, 200), response.code);
    try expectEqualSlices(u8, "OK", response.message);
    const expectedHeaders = [_]cc.Header {
        .{
            .name = "Content-Type",
            .value = "text/plain",
        },
    };
    try expectHeaders(&expectedHeaders, response.headers[0..response.numHeaders]);
    try expectEqualSlices(u8, "Hello, world!", response.body);
}
