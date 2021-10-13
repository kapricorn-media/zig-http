const std = @import("std");
const ssl = @import("ssl");
const ziget = @import("ziget");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const libhttp = @import("libhttp.zig");

const c = @cImport(@cInclude("unistd.h"));
const cc = @import("client.zig");

test "success: port 9000, no SSL"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const context = try libhttp.start(9000, false, "", &gpa.allocator);
    defer libhttp.stop(context);
    
    try expect(!gpa.deinit()); // TODO ideally this should be defer'd at the start
}

fn handlerNullData(connection: *libhttp.mg_connection, data: ?*c_void) !void
{
    _ = connection;
    try expectEqual(data, null);
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

// const TRUSTY_URL = "www.google.com";

// test "http GET, trusty URL"
// {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};

//     var responseData: std.ArrayList(u8) = undefined;
//     var response: cc.Response = undefined;
//     try cc.httpGet(TRUSTY_URL, "/", &gpa.allocator, &responseData, &response);
//     try expect(response.code == 200);
//     try expect(std.mem.eql(u8, response.message, "OK"));
//     try expect(response.body.len > 0);

//     responseData.deinit();
//     try expect(!gpa.deinit());
// }

// test "https GET request, trusty URL"
// {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};

//     var responseData: std.ArrayList(u8) = undefined;
//     var response: cc.Response = undefined;
//     try cc.httpsGet(TRUSTY_URL, "/", &gpa.allocator, &responseData, &response);
//     try expect(response.code == 200);
//     try expect(std.mem.eql(u8, response.message, "OK"));
//     try expect(response.body.len > 0);

//     responseData.deinit();
//     try expect(!gpa.deinit());
// }

fn handlerNoResponse(connection: *libhttp.mg_connection, data: ?*c_void) !void
{
    _ = connection;
    try expectEqual(data, null);
}

test "http localhost, no response"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const port = 9000;

    const context = try libhttp.start(port, false, "", &gpa.allocator);
    defer libhttp.stop(context);
    libhttp.setRequestHandler(context, "/", handlerNoResponse, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: cc.Response = undefined;
    cc.get(false, port, "localhost", "/", &gpa.allocator, &responseData, &response) catch {
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

test "http localhost, 200 OK"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const port = 9000;

    const context = try libhttp.start(port, false, "", &gpa.allocator);
    defer libhttp.stop(context);
    libhttp.setRequestHandler(context, "/", handlerOk, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: cc.Response = undefined;
    try cc.get(false, port, "localhost", "/", &gpa.allocator, &responseData, &response);
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

test "http localhost, 500"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const port = 9000;

    const context = try libhttp.start(port, false, "", &gpa.allocator);
    defer libhttp.stop(context);
    libhttp.setRequestHandler(context, "/", handlerInternalError, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: cc.Response = undefined;
    try cc.get(false, port, "localhost", "/", &gpa.allocator, &responseData, &response);
    try expectEqual(response.code, 500);
    try expectEqualSlices(u8, response.message, "Internal Server Error");
    try expectEqual(response.body.len, 0);
}

fn handlerHelloWorld(connection: *libhttp.mg_connection, data: ?*c_void) !void
{
    try expectEqual(data, null);
    try libhttp.writeHttpCode(connection, ._200);
    try libhttp.writeHttpEndHeader(connection);
    const str = "Hello, world!";
    try expectEqual(libhttp.mg_write(connection, &str[0], str.len), str.len);
}

test "http localhost, 200, return data"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const port = 9000;

    const context = try libhttp.start(port, false, "", &gpa.allocator);
    defer libhttp.stop(context);
    libhttp.setRequestHandler(context, "/", handlerHelloWorld, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: cc.Response = undefined;
    try cc.get(false, port, "localhost", "/", &gpa.allocator, &responseData, &response);
    try expectEqual(response.code, 200);
    try expectEqualSlices(u8, response.message, "OK");
    try expectEqualSlices(u8, response.body, "Hello, world!");
}
