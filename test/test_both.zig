const std = @import("std");
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const client = @import("http-client");
const http = @import("http-common");
const server = @import("http-server");

const TEST_IP = "127.0.0.1";
const TEST_HOST = "localhost";
const TEST_PORT = 19191;

const TEST_LOCALHOST_CRT = @embedFile("localhost.crt");
const TEST_LOCALHOST_KEY = @embedFile("localhost.key");

var _serverThread: std.Thread = undefined;
var _failed = std.atomic.Atomic(bool).init(false);

fn serverThreadFn(comptime UserDataType: type) fn(s: *server.Server(UserDataType)) void
{
    const Wrapper = struct {
        fn function(s: *server.Server(UserDataType)) void
        {
            s.listen(TEST_IP, TEST_PORT) catch |err| {
                std.log.err("server listen error {}", .{err});
                _failed.store(true, .Release);
            };
        }
    };
    return Wrapper.function;
}

fn serverThreadStartAndWait(comptime UserDataType: type, s: *server.Server(UserDataType)) !void
{
    const threadFn = comptime serverThreadFn(UserDataType);
    _serverThread = try std.Thread.spawn(.{}, threadFn, .{s});
    while (true) {
        if (_failed.load(.Acquire)) {
            return error.serverListenFailed;
        }
        if (s.isListening()) {
            break;
        }
    }
}

fn createHttpCodeCallback(comptime code: http.Code) server.Server(void).CallbackType
{
    const Wrapper = struct {
        fn callback(_: void, request: server.Request, writer: server.Writer) !void
        {
            try expectEqual(http.Method.Get, request.method);
            try expectEqualSlices(u8, "/", request.uri);
            try expectEqual(http.Version.v1_1, request.version);
            try expectEqual(@as(usize, 0), request.body.len);
            try expectEqual(@as(usize, 0), try http.getContentLength(request));

            try server.writeCode(writer, code);
            try server.writeEndHeader(writer);
        }
    };
    return Wrapper.callback;
}

test "HTTPS GET / not trusted"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});
    var allocator = gpa.allocator();

    const Wrapper = struct {
        fn callback(_: void, request: server.Request, writer: server.Writer) !void
        {
            // Request shouldn't go through
            _ = request; _ = writer;
            try expect(false);
        }
    };

    const httpsOptions = server.HttpsOptions {
        .certChainFileData = TEST_LOCALHOST_CRT,
        .privateKeyFileData = TEST_LOCALHOST_KEY,
    };
    var s = try server.Server(void).init(Wrapper.callback, {}, httpsOptions, allocator);
    defer s.deinit();
    try serverThreadStartAndWait(void, &s);
    defer {
        s.stop();
        _serverThread.join();
    }

    // localhost certificate not in trusted CAs, should fail
    try expectError(
        client.RequestError.HttpsError,
        client.get(true, TEST_PORT, "localhost", "/", null, allocator)
    );
}

fn testCode(comptime code: http.Code, https: bool, allocator: std.mem.Allocator) !void
{
    const callback = createHttpCodeCallback(code);
    const httpsOptions = if (https) server.HttpsOptions {
        .certChainFileData = TEST_LOCALHOST_CRT,
        .privateKeyFileData = TEST_LOCALHOST_KEY,
    } else null;
    var s = try server.Server(void).init(callback, {}, httpsOptions, allocator);
    defer s.deinit();
    try serverThreadStartAndWait(void, &s);
    defer {
        s.stop();
        _serverThread.join();
    }

    try client.overrideRootCaList(TEST_LOCALHOST_CRT, allocator);
    defer client.freeOverrideRootCaList(allocator);
    const response = try client.get(https, TEST_PORT, TEST_HOST, "/", null, allocator);
    defer response.deinit();

    try expectEqual(code, response.code);
    const message = http.getCodeMessage(code);
    try expectEqualSlices(u8, message, response.message);
    try expectEqual(@as(usize, 0), response.body.len);
}

test "GET / all codes, no data"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});
    var allocator = gpa.allocator();

    inline for (@typeInfo(http.Code).Enum.fields) |f| {
        const code = @field(http.Code, f.name);
        try testCode(code, false, allocator);
        try testCode(code, true, allocator);
    }
}

fn createHttpUriCallback(comptime uri: []const u8, comptime response: []const u8) server.Server(void).CallbackType
{
    const Wrapper = struct {
        fn callback(_: void, request: server.Request, writer: server.Writer) !void
        {
            try expectEqual(http.Method.Get, request.method);
            try expectEqual(http.Version.v1_1, request.version);
            try expectEqual(@as(usize, 0), request.body.len);
            try expectEqual(@as(usize, 0), try http.getContentLength(request));

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
    const httpsOptions = if (https) server.HttpsOptions {
        .certChainFileData = TEST_LOCALHOST_CRT,
        .privateKeyFileData = TEST_LOCALHOST_KEY,
    } else null;
    var s = try server.Server(void).init(callback, {}, httpsOptions, allocator);
    defer s.deinit();
    try serverThreadStartAndWait(void, &s);
    defer {
        s.stop();
        _serverThread.join();
    }

    try client.overrideRootCaList(TEST_LOCALHOST_CRT, allocator);
    defer client.freeOverrideRootCaList(allocator);

    const response1 = try client.get(https, TEST_PORT, TEST_HOST, uri, null, allocator);
    defer response1.deinit();

    try expectEqual(http.Code._200, response1.code);
    try expectEqualSlices(u8, "OK", response1.message);
    try expectEqualSlices(u8, out, response1.body);
    try expectEqual(out.len, try http.getContentLength(response1));

    const response2 = try client.get(https, TEST_PORT, TEST_HOST, "/", null, allocator);
    defer response2.deinit();

    try expectEqual(http.Code._404, response2.code);
    try expectEqualSlices(u8, "Not Found", response2.message);
    try expectEqual(@as(usize, 0), response2.body.len);

    const response3 = try client.get(https, TEST_PORT, TEST_HOST, "/this_is_the_wrong_uri", null, allocator);
    defer response3.deinit();

    try expectEqual(http.Code._404, response3.code);
    try expectEqualSlices(u8, "Not Found", response3.message);
    try expectEqual(@as(usize, 0), response3.body.len);
}

test "GET different URIs"
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
        // try testUri(uri, true, allocator);
    }
}

fn createDataCallback(comptime in: []const u8, comptime out: []const u8) server.Server(void).CallbackType
{
    const Wrapper = struct {
        fn callback(_: void, request: server.Request, writer: server.Writer) !void
        {
            try expectEqual(http.Method.Post, request.method);
            try expectEqualSlices(u8, "/", request.uri);
            try expectEqual(http.Version.v1_1, request.version);
            try expectEqualSlices(u8, in, request.body);
            try expectEqual(in.len, try http.getContentLength(request));

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
    const httpsOptions = if (https) server.HttpsOptions {
        .certChainFileData = TEST_LOCALHOST_CRT,
        .privateKeyFileData = TEST_LOCALHOST_KEY,
    } else null;
    var s = try server.Server(void).init(callback, {}, httpsOptions, allocator);
    defer s.deinit();
    try serverThreadStartAndWait(void, &s);
    defer {
        s.stop();
        _serverThread.join();
    }

    try client.overrideRootCaList(TEST_LOCALHOST_CRT, allocator);
    defer client.freeOverrideRootCaList(allocator);
    const response = try client.post(https, TEST_PORT, TEST_HOST, "/", null, in, allocator);
    defer response.deinit();

    try expectEqual(http.Code._200, response.code);
    try expectEqualSlices(u8, "OK", response.message);
    try expectEqualSlices(u8, out, response.body);
    try expectEqual(out.len, try http.getContentLength(response));
}

test "POST / 200 data in/out"
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
        // try testDataInOut(p.in, p.out, true, allocator);
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
        fn callback(_: void, request: server.Request, writer: server.Writer) !void
        {
            try expectEqual(http.Method.Get, request.method);
            try expectEqualSlices(u8, "/", request.uri);
            try expectEqual(http.Version.v1_1, request.version);
            try expectEqual(@as(usize, 0), request.body.len);
            try expectEqual(@as(usize, 0), try http.getContentLength(request));

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

    const httpsOptions = if (https) server.HttpsOptions {
        .certChainFileData = TEST_LOCALHOST_CRT,
        .privateKeyFileData = TEST_LOCALHOST_KEY,
    } else null;
    var s = try server.Server(void).init(Wrapper.callback, {}, httpsOptions, allocator);
    defer s.deinit();
    try serverThreadStartAndWait(void, &s);
    defer {
        s.stop();
        _serverThread.join();
    }

    try client.overrideRootCaList(TEST_LOCALHOST_CRT, allocator);
    defer client.freeOverrideRootCaList(allocator);
    const response = try client.get(https, TEST_PORT, TEST_HOST, "/", &requestHeaders, allocator);
    defer response.deinit();

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

test "GET / 200 custom headers"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});
    var allocator = gpa.allocator();

    try testCustomHeaders(false, allocator);
    // try testCustomHeaders(true, allocator);
}

fn testStatic(https: bool, allocator: std.mem.Allocator) !void
{
    const State = struct {
        allocator: std.mem.Allocator,
    };

    const Wrapper = struct {
        fn callback(state: *const State, request: server.Request, writer: server.Writer) !void
        {
            try expectEqual(http.Method.Get, request.method);
            try expectEqualSlices(u8, "/localhost.crt", request.uri);
            try expectEqual(http.Version.v1_1, request.version);
            try expectEqual(@as(usize, 0), request.body.len);
            try expectEqual(@as(usize, 0), try http.getContentLength(request));

            try server.serveStatic(writer, request.uri, "test", state.allocator);
        }
    };

    const state = State {
        .allocator = allocator,
    };
    const httpsOptions = if (https) server.HttpsOptions {
        .certChainFileData = TEST_LOCALHOST_CRT,
        .privateKeyFileData = TEST_LOCALHOST_KEY,
    } else null;
    var s = try server.Server(*const State).init(Wrapper.callback, &state, httpsOptions, allocator);
    defer s.deinit();
    try serverThreadStartAndWait(*const State, &s);
    defer {
        s.stop();
        _serverThread.join();
    }

    try client.overrideRootCaList(TEST_LOCALHOST_CRT, allocator);
    defer client.freeOverrideRootCaList(allocator);
    const response = try client.get(https, TEST_PORT, TEST_HOST, "/localhost.crt", null, allocator);
    defer response.deinit();

    try expectEqual(http.Code._200, response.code);
    try expectEqualSlices(u8, "OK", response.message);
    try expectEqualSlices(u8, TEST_LOCALHOST_CRT, response.body);
    try expectEqual(TEST_LOCALHOST_CRT.len, try http.getContentLength(response));
}

test "serve static"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});
    var allocator = gpa.allocator();

    try testStatic(false, allocator);
    // try testStatic(true, allocator);
}

fn testQueryParams(https: bool, allocator: std.mem.Allocator) !void
{
    const uri = "/this/is/a/test/uri";
    const queryString = "?param1=value1&param2=value2&param3=value3&hello=world";
    const params = [_]http.QueryParam {
        .{.name = "param1", .value = "value1"},
        .{.name = "param2", .value = "value2"},
        .{.name = "param3", .value = "value3"},
        .{.name = "hello", .value = "world"},
    };
    const uriFull = uri ++ queryString;

    const Wrapper = struct {
        fn callback(_: void, request: server.Request, writer: server.Writer) !void
        {
            try expectEqual(http.Method.Get, request.method);
            try expectEqualSlices(u8, uriFull, request.uriFull);
            try expectEqualSlices(u8, uri, request.uri);
            try expectEqual(http.Version.v1_1, request.version);
            try expectEqual(@as(usize, 0), request.body.len);
            try expectEqual(@as(usize, 0), try http.getContentLength(request));
            try expectEqual(params.len, request.queryParams.len);
            for (params) |_, i| {
                try expectEqualSlices(u8, params[i].name, request.queryParams[i].name);
                try expectEqualSlices(u8, params[i].value, request.queryParams[i].value);
            }

            try server.writeCode(writer, ._200);
            try server.writeEndHeader(writer);
        }
    };

    const httpsOptions = if (https) server.HttpsOptions {
        .certChainFileData = TEST_LOCALHOST_CRT,
        .privateKeyFileData = TEST_LOCALHOST_KEY,
    } else null;
    var s = try server.Server(void).init(Wrapper.callback, {}, httpsOptions, allocator);
    defer s.deinit();
    try serverThreadStartAndWait(void, &s);
    defer {
        s.stop();
        _serverThread.join();
    }

    try client.overrideRootCaList(TEST_LOCALHOST_CRT, allocator);
    defer client.freeOverrideRootCaList(allocator);
    const response = try client.get(https, TEST_PORT, TEST_HOST, uriFull, null, allocator);
    defer response.deinit();

    try expectEqual(http.Code._200, response.code);
    try expectEqualSlices(u8, "OK", response.message);
    try expectEqual(@as(usize, 0), response.body.len);
}

test "query params"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});
    var allocator = gpa.allocator();

    try testQueryParams(false, allocator);
    // try testQueryParams(true, allocator);
}
