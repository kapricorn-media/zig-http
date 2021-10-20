const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const client = @import("http-client");
const server = @import("http-server");

const TEST_PORT = 19191;
const TEST_PORT_STR = std.fmt.comptimePrint("{}", .{TEST_PORT});
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

fn checkRequestHeaders(connection: *server.mg_connection, numHeaders: c_int) !void
{
    const requestInfo = server.mg_get_request_info(connection);
    try expectEqualSlices(u8, "GET", std.mem.span(requestInfo.*.request_method));
    // try expectEqualSlices(u8, "/", std.mem.span(requestInfo.*.request_uri));
    try expectEqualSlices(u8, "1.1", std.mem.span(requestInfo.*.http_version));
    try expectEqual(@as(?*const u8, null), requestInfo.*.query_string);
    try expect(numHeaders >= 3);
    try expectEqual(numHeaders, requestInfo.*.num_headers);
    try expectEqualSlices(u8, "Host", std.mem.span(requestInfo.*.http_headers[0].name));
    try expectEqualSlices(u8, TEST_HOSTNAME ++ ":" ++ TEST_PORT_STR, std.mem.span(requestInfo.*.http_headers[0].value));
    try expectEqualSlices(u8, "Connection", std.mem.span(requestInfo.*.http_headers[1].name));
    try expectEqualSlices(u8, "close", std.mem.span(requestInfo.*.http_headers[1].value));
    try expectEqualSlices(u8, "Content-Length", std.mem.span(requestInfo.*.http_headers[2].name));
    try expectEqualSlices(u8, "0", std.mem.span(requestInfo.*.http_headers[2].value));

    try expectEqual(@as(c_longlong, 0), requestInfo.*.content_length);
}

// server tests

test "server, no SSL"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});

    const context = try server.start(TEST_PORT, false, "", &gpa.allocator);
    defer server.stop(context);
}

fn handlerNullData(connection: *server.mg_connection, data: ?*c_void) !void
{
    _ = connection;
    try expectEqual(@as(?*c_void, null), data);
}

test "server, no SSL, request handler"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});

    const context = try server.start(TEST_PORT, false, "", &gpa.allocator);
    defer server.stop(context);

    server.setRequestHandler(context, "/", handlerNullData, null);
}

test "server, SSL, no cert, FAIL"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});

    try expectAnyError(server.start(TEST_PORT, true, "", &gpa.allocator));
}

// server+client tests

fn expectHeaders(expected: []const client.Header, actual: []const client.Header) !void
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

fn handlerNoResponse(connection: *server.mg_connection, data: ?*c_void) !void
{
    _ = connection;

    try expectEqual(@as(?*c_void, null), data);

    try checkRequestHeaders(connection, 3);
}

test "server+client, get /, no response"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});

    const context = try server.start(TEST_PORT, false, "", &gpa.allocator);
    defer server.stop(context);
    server.setRequestHandler(context, "/", handlerNoResponse, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    try expectAnyError(client.get(false, TEST_PORT, TEST_HOSTNAME, "/", null, &gpa.allocator, &responseData, &response));
}

fn handlerOk(connection: *server.mg_connection, data: ?*c_void) !void
{
    try expectEqual(@as(?*c_void, null), data);

    try checkRequestHeaders(connection, 3);

    try server.writeHttpCode(connection, ._200);
    try server.writeHttpEndHeader(connection);
}

test "server+client, get /, 200"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});

    const context = try server.start(TEST_PORT, false, "", &gpa.allocator);
    defer server.stop(context);
    server.setRequestHandler(context, "/", handlerOk, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    try client.get(false, TEST_PORT, TEST_HOSTNAME, "/", null, &gpa.allocator, &responseData, &response);
    defer responseData.deinit();
    try expectEqual(@as(u32, 200), response.code);
    try expectEqualSlices(u8, "OK", response.message);
    try expectEqual(@as(usize, 0), response.body.len);
}

fn handlerInternalError(connection: *server.mg_connection, data: ?*c_void) !void
{
    try expectEqual(@as(?*c_void, null), data);

    try checkRequestHeaders(connection, 3);

    try server.writeHttpCode(connection, ._500);
    try server.writeHttpEndHeader(connection);
}

test "server+client, get /, 500"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});

    const context = try server.start(TEST_PORT, false, "", &gpa.allocator);
    defer server.stop(context);
    server.setRequestHandler(context, "/", handlerInternalError, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    try client.get(false, TEST_PORT, TEST_HOSTNAME, "/", null, &gpa.allocator, &responseData, &response);
    defer responseData.deinit();
    try expectEqual(@as(u32, 500), response.code);
    try expectEqualSlices(u8, "Internal Server Error", response.message);
    try expectEqual(@as(usize, 0), response.body.len);
}

fn handlerHelloWorld(connection: *server.mg_connection, data: ?*c_void) !void
{
    try expectEqual(@as(?*c_void, null), data);

    try checkRequestHeaders(connection, 3);

    try server.writeHttpCode(connection, ._200);
    try server.writeHttpContentType(connection, .TextPlain);
    try server.writeHttpEndHeader(connection);
    const str = "Hello, world!";
    try expectEqual(@as(c_int, str.len), server.mg_write(connection, &str[0], str.len));
}

test "server+client, get /, 200, return data"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});

    const context = try server.start(TEST_PORT, false, "", &gpa.allocator);
    defer server.stop(context);
    server.setRequestHandler(context, "/", handlerHelloWorld, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    try client.get(false, TEST_PORT, TEST_HOSTNAME, "/", null, &gpa.allocator, &responseData, &response);
    defer responseData.deinit();
    try expectEqual(@as(u32, 200), response.code);
    try expectEqualSlices(u8, "OK", response.message);
    const expectedHeaders = [_]client.Header {
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
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});

    const context = try server.start(TEST_PORT, false, "", &gpa.allocator);
    defer server.stop(context);
    server.setRequestHandler(context, "/custom_uri", handlerHelloWorld, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    try client.get(false, TEST_PORT, TEST_HOSTNAME, "/custom_uri", null, &gpa.allocator, &responseData, &response);
    defer responseData.deinit();
    try expectEqual(@as(u32, 200), response.code);
    try expectEqualSlices(u8, "OK", response.message);
    const expectedHeaders = [_]client.Header {
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
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});

    const context = try server.start(TEST_PORT, false, "", &gpa.allocator);
    defer server.stop(context);
    server.setRequestHandler(context, "/custom_uri", handlerHelloWorld, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    try client.get(false, TEST_PORT, TEST_HOSTNAME, "/", null, &gpa.allocator, &responseData, &response);
    defer responseData.deinit();
    try expectEqual(@as(u32, 404), response.code);
    try expectEqualSlices(u8, "Not Found", response.message);
}

test "server+client, get /custom_uri, serve /"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});

    const context = try server.start(TEST_PORT, false, "", &gpa.allocator);
    defer server.stop(context);
    server.setRequestHandler(context, "/", handlerHelloWorld, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    try client.get(false, TEST_PORT, TEST_HOSTNAME, "/custom_uri", null, &gpa.allocator, &responseData, &response);
    defer responseData.deinit();
    try expectEqual(@as(u32, 200), response.code);
    try expectEqualSlices(u8, "OK", response.message);
    const expectedHeaders = [_]client.Header {
        .{
            .name = "Content-Type",
            .value = "text/plain",
        },
    };
    try expectHeaders(&expectedHeaders, response.headers[0..response.numHeaders]);
    try expectEqualSlices(u8, "Hello, world!", response.body);
}

test "server+client, get /custom_uri, serve / and /custom_uri"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});

    const context = try server.start(TEST_PORT, false, "", &gpa.allocator);
    defer server.stop(context);
    server.setRequestHandler(context, "/", handlerHelloWorld, null);
    server.setRequestHandler(context, "/custom_uri", handlerNoResponse, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    try client.get(false, TEST_PORT, TEST_HOSTNAME, "/", null, &gpa.allocator, &responseData, &response);
    try expectEqual(@as(u32, 200), response.code);
    try expectEqualSlices(u8, "OK", response.message);
    const expectedHeaders = [_]client.Header {
        .{
            .name = "Content-Type",
            .value = "text/plain",
        },
    };
    try expectHeaders(&expectedHeaders, response.headers[0..response.numHeaders]);
    try expectEqualSlices(u8, "Hello, world!", response.body);
    responseData.deinit();

    try client.get(false, TEST_PORT, TEST_HOSTNAME, "/custom_uri2", null, &gpa.allocator, &responseData, &response);
    try expectEqual(@as(u32, 200), response.code);
    try expectEqualSlices(u8, "OK", response.message);
    try expectHeaders(&expectedHeaders, response.headers[0..response.numHeaders]);
    try expectEqualSlices(u8, "Hello, world!", response.body);
    responseData.deinit();

    try expectAnyError(client.get(false, TEST_PORT, TEST_HOSTNAME, "/custom_uri", null, &gpa.allocator, &responseData, &response));
}

fn handlerHeaders(connection: *server.mg_connection, data: ?*c_void) !void
{
    try expectEqual(@as(?*c_void, null), data);

    try checkRequestHeaders(connection, 5);
    const requestInfo = server.mg_get_request_info(connection);
    try expectEqualSlices(u8, "Time", std.mem.span(requestInfo.*.http_headers[3].name));
    try expectEqualSlices(u8, "420", std.mem.span(requestInfo.*.http_headers[3].value));
    try expectEqualSlices(u8, "CustomHeader", std.mem.span(requestInfo.*.http_headers[4].name));
    try expectEqualSlices(u8, "CustomValue", std.mem.span(requestInfo.*.http_headers[4].value));

    try server.writeHttpCode(connection, ._200);
    try server.writeHttpContentType(connection, .TextPlain);
    try server.writeHttpEndHeader(connection);
    const str = "Hello, world!";
    try expectEqual(@as(c_int, str.len), server.mg_write(connection, &str[0], str.len));
}

test "server+client, get /, 200, send headers"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});

    const context = try server.start(TEST_PORT, false, "", &gpa.allocator);
    defer server.stop(context);
    server.setRequestHandler(context, "/", handlerHeaders, null);

    var responseData: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    const headers = [_]client.Header {
        .{
            .name = "Time",
            .value = "420",
        },
        .{
            .name = "CustomHeader",
            .value = "CustomValue",
        },
    };
    try client.get(false, TEST_PORT, TEST_HOSTNAME, "/", &headers, &gpa.allocator, &responseData, &response);
    defer responseData.deinit();
    try expectEqual(@as(u32, 200), response.code);
    try expectEqualSlices(u8, "OK", response.message);
    const expectedHeaders = [_]client.Header {
        .{
            .name = "Content-Type",
            .value = "text/plain",
        },
    };
    try expectHeaders(&expectedHeaders, response.headers[0..response.numHeaders]);
    try expectEqualSlices(u8, "Hello, world!", response.body);
}
