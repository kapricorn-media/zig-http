const std = @import("std");
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const client = @import("http-client");
const http = @import("http-common");
const server = @import("http-server");

const TEST_IP = "127.0.0.1";
const TEST_PORT = 19191;
const TEST_HOST = std.fmt.comptimePrint("{s}:{}", .{TEST_IP, TEST_PORT});

var _serverThread: std.Thread = undefined;
var _failed = std.atomic.Atomic(bool).init(false);

fn serverThread(s: *server.Server) void
{
    s.listen(TEST_IP, TEST_PORT) catch |err| {
        std.log.err("server listen error {}", .{err});
        _failed.store(true, .Release);
    };
}

fn serverThreadStartAndWait(s: *server.Server) !void
{
    _serverThread = try std.Thread.spawn(.{}, serverThread, .{s});
    while (true) {
        if (_failed.load(.Acquire)) {
            return error.serverListenFailed;
        }
        if (s.isListening()) {
            break;
        }
    }
}

fn createHttpCodeCallback(comptime code: http.Code) server.CallbackType
{
    const Wrapper = struct {
        fn callback(request: *const server.Request, writer: server.Writer) !void
        {
            try expectEqual(http.Method.Get, request.method);
            try expectEqualSlices(u8, "/", request.uri);
            try expectEqual(http.Version.v1_1, request.version);
            try expectEqual(@as(usize, 0), request.body.len);
            if (http.getContentLength(request)) |contentLength| {
                try expectEqual(@as(usize, 0), contentLength);
            } else {
                return error.NoContentLength;
            }

            try server.writeCode(writer, code);
            try server.writeEndHeader(writer);
        }
    };
    return Wrapper.callback;
}

test "HTTPS GET / 200"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});
    var allocator = gpa.allocator();

    const Wrapper = struct {
        fn callback(request: *const server.Request, writer: server.Writer) !void
        {
            _ = request;
            try server.writeCode(writer, ._200);
            try server.writeEndHeader(writer);
        }
    };

    const httpsOptions = server.HttpsOptions {
        .certChainFileData = @embedFile("localhost.crt"),
        .privateKeyFileData = @embedFile("localhost.key"),
    };
    var s = try server.Server.init(Wrapper.callback, httpsOptions, allocator);
    defer s.deinit();
    try serverThreadStartAndWait(&s);
    defer {
        s.stop();
        _serverThread.join();
    }

    var responseData: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    // localhost certificate not in trusted CAs
    try expectError(
        client.RequestError.HttpsError,
        client.get(true, TEST_PORT, "localhost", "/", null, allocator, &responseData, &response)
    );
}

fn testCode(comptime code: http.Code, https: bool, allocator: std.mem.Allocator) !void
{
    const callback = createHttpCodeCallback(code);
    var s = try server.Server.init(callback, null, allocator);
    defer s.deinit();
    try serverThreadStartAndWait(&s);
    defer {
        s.stop();
        _serverThread.join();
    }

    var responseData: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    try client.get(https, TEST_PORT, TEST_IP, "/", null, allocator, &responseData, &response);
    defer responseData.deinit();

    try expectEqual(code, response.code);
    const message = http.getCodeMessage(code);
    try expectEqualSlices(u8, message, response.message);
    try expectEqual(@as(usize, 0), response.body.len);
}

test "HTTP GET / all codes, no data"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});
    var allocator = gpa.allocator();

    inline for (@typeInfo(http.Code).Enum.fields) |f| {
        const code = @field(http.Code, f.name);
        try testCode(code, false, allocator);
        // try testCode(code, true, allocator);
    }
}

fn createHttpUriCallback(comptime uri: []const u8, comptime response: []const u8) server.CallbackType
{
    const Wrapper = struct {
        fn callback(request: *const server.Request, writer: server.Writer) !void
        {
            try expectEqual(http.Method.Get, request.method);
            try expectEqual(http.Version.v1_1, request.version);
            try expectEqual(@as(usize, 0), request.body.len);
            if (http.getContentLength(request)) |contentLength| {
                try expectEqual(@as(usize, 0), contentLength);
            } else {
                return error.NoContentLength;
            }

            if (std.mem.eql(u8, request.uri, uri)) {
                try server.writeCode(writer, ._200);
                try server.writeContentLength(writer, response.len);
                try server.writeEndHeader(writer);
                try writer.writeAll(response);
            } else {
                try server.writeCode(writer, ._404);
                try server.writeEndHeader(writer);
            }
        }
    };
    return Wrapper.callback;
}

fn testUri(comptime uri: []const u8, https: bool, allocator: std.mem.Allocator) !void
{
    const out = "Hello. That is the correct URI!";

    const callback = createHttpUriCallback(uri, out);
    try expect(!https);
    var s = try server.Server.init(callback, null, allocator);
    defer s.deinit();
    try serverThreadStartAndWait(&s);
    defer {
        s.stop();
        _serverThread.join();
    }

    var responseData: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    try client.get(https, TEST_PORT, TEST_IP, uri, null, allocator, &responseData, &response);

    try expectEqual(http.Code._200, response.code);
    try expectEqualSlices(u8, "OK", response.message);
    try expectEqualSlices(u8, out, response.body);
    if (http.getContentLength(response)) |contentLength| {
        try expectEqual(out.len, contentLength);
    } else {
        return error.NoContentLength;
    }

    responseData.deinit();
    try client.get(https, TEST_PORT, TEST_IP, "/", null, allocator, &responseData, &response);

    try expectEqual(http.Code._404, response.code);
    try expectEqualSlices(u8, "Not Found", response.message);
    try expectEqual(@as(usize, 0), response.body.len);

    responseData.deinit();
    try client.get(https, TEST_PORT, TEST_IP, "/this_is_the_wrong_uri", null, allocator, &responseData, &response);

    try expectEqual(http.Code._404, response.code);
    try expectEqualSlices(u8, "Not Found", response.message);
    try expectEqual(@as(usize, 0), response.body.len);

    responseData.deinit();
}

test "HTTP GET different URIs"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});
    var allocator = gpa.allocator();

    const uris = [_][]const u8 {
        "/testing",
        "/hello_world",
    };

    inline for (uris) |uri| {
        try testUri(uri, false, allocator);
    }
}

fn createDataCallback(comptime in: []const u8, comptime out: []const u8) server.CallbackType
{
    const Wrapper = struct {
        fn callback(request: *const server.Request, writer: server.Writer) !void
        {
            try expectEqual(http.Method.Post, request.method);
            try expectEqualSlices(u8, "/", request.uri);
            try expectEqual(http.Version.v1_1, request.version);
            try expectEqualSlices(u8, in, request.body);
            if (http.getContentLength(request)) |contentLength| {
                try expectEqual(in.len, contentLength);
            } else {
                return error.NoContentLength;
            }

            try server.writeCode(writer, ._200);
            try server.writeContentLength(writer, out.len);
            try server.writeEndHeader(writer);
            try writer.writeAll(out);
        }
    };
    return Wrapper.callback;
}

fn testDataInOut(
    comptime in: []const u8,
    comptime out: []const u8,
    https: bool, 
    allocator: std.mem.Allocator) !void
{
    const callback = createDataCallback(in, out);
    try expect(!https);
    var s = try server.Server.init(callback, null, allocator);
    defer s.deinit();
    try serverThreadStartAndWait(&s);
    defer {
        s.stop();
        _serverThread.join();
    }

    var responseData: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    try client.post(https, TEST_PORT, TEST_IP, "/", null, in, allocator, &responseData, &response);
    defer responseData.deinit();

    try expectEqual(http.Code._200, response.code);
    try expectEqualSlices(u8, "OK", response.message);
    try expectEqualSlices(u8, out, response.body);
    if (http.getContentLength(response)) |contentLength| {
        try expectEqual(out.len, contentLength);
    } else {
        return error.NoContentLength;
    }
}

test "HTTP POST / 200 data in/out"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});
    var allocator = gpa.allocator();

    const Params = struct {
        in: []const u8,
        out: []const u8,
    };
    const params = &[_]Params {
        .{
            .in = "hello",
            .out = "world",
        },
        .{
            .in = "你好",
            .out = "世界",
        },
        .{
            .in = "",
            .out = "",
        },
        .{
            .in = "19id(!@(@D()@!)012mf-12m-))()&)*_#2-3m c- [d[a]c[\\\n\r\n\n\r\n\r\n",
            .out = "19id(!@(@D()@!)012mf[\\\n\r\n\r\n\r\noid239ei9(W*DHY&*Q@&(*!))KDkkx",
        },
    };

    inline for (params) |p| {
        try testDataInOut(p.in, p.out, false, allocator);
    }
}

fn testCustomHeaders(https: bool, allocator: std.mem.Allocator) !void
{
    const requestHeaders = [_]http.Header {
        .{
            .name = "Custom-Header-Request",
            .value = "12345678",
        },
        .{
            .name = "testing space",
            .value = "::::::",
        },
        .{
            .name = "this_one_is_kinda_weird",
            .value = "k maybe not : hallo",
        },
    };
    const responseHeaders = [_]http.Header {
        .{
            .name = "Custom-Header-Response",
            .value = "87654321",
        },
        .{
            .name = "198328987r873(#*&FW#",
            .value = "AOFI9SD;;:",
        },
        .{
            .name = "Session",
            .value = "19ae9a8bf9a9c",
        },
    };

    const Wrapper = struct {
        fn callback(request: *const server.Request, writer: server.Writer) !void
        {
            try expectEqual(http.Method.Get, request.method);
            try expectEqualSlices(u8, "/", request.uri);
            try expectEqual(http.Version.v1_1, request.version);
            try expectEqual(@as(usize, 0), request.body.len);
            if (http.getContentLength(request)) |contentLength| {
                try expectEqual(@as(usize, 0), contentLength);
            } else {
                return error.NoContentLength;
            }

            for (requestHeaders) |header| {
                if (http.getHeader(request, header.name)) |value| {
                    try expectEqualSlices(u8, header.value, value);
                } else {
                    return error.MissingHeader;
                }
            }
            for (responseHeaders) |header| {
                try expectEqual(@as(?[]const u8, null), http.getHeader(request, header.name));
            }

            try server.writeCode(writer, ._200);
            for (responseHeaders) |header| {
                try server.writeHeader(writer, header);
            }
            try server.writeEndHeader(writer);
        }
    };

    try expect(!https);
    var s = try server.Server.init(Wrapper.callback, null, allocator);
    defer s.deinit();
    try serverThreadStartAndWait(&s);
    defer {
        s.stop();
        _serverThread.join();
    }

    var responseData: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    try client.get(https, TEST_PORT, TEST_IP, "/", &requestHeaders, allocator, &responseData, &response);
    defer responseData.deinit();

    try expectEqual(http.Code._200, response.code);
    try expectEqualSlices(u8, "OK", response.message);
    try expectEqual(@as(usize, 0), response.body.len);

    for (requestHeaders) |header| {
        try expectEqual(@as(?[]const u8, null), http.getHeader(response, header.name));
    }
    for (responseHeaders) |header| {
        if (http.getHeader(response, header.name)) |value| {
            try expectEqualSlices(u8, header.value, value);
        } else {
            return error.MissingHeader;
        }
    }
}

test "HTTP GET / 200 custom headers"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});
    var allocator = gpa.allocator();

    try testCustomHeaders(false, allocator);
}
