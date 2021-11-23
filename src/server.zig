const std = @import("std");

const cw = @import("civetweb.zig");
pub usingnamespace cw;

pub const HttpCode = enum(u32)
{
    _200 = 200,
    _301 = 301,
    _400 = 400,
    _401 = 401,
    _404 = 404,
    _500 = 500,
};

pub const HttpContentType = enum
{
    TextPlain,
    TextHtml,
    ApplicationJson,
    ApplicationOctetStream,
};

pub fn writeHttpCode(connection: *cw.mg_connection, code: HttpCode) !void
{
    const bufSize = 1024;
    var buf: [bufSize]u8 = undefined;

    const string = switch (code) {
        ._200 => "OK",
        ._301 => "Moved Permanently",
        ._400 => "Bad Request",
        ._401 => "Unauthorized",
        ._404 => "Not Found",
        ._500 => "Internal Server Error"
    };
    const response = try std.fmt.bufPrint(&buf, "HTTP/1.1 {} {s}\r\n", .{
        @enumToInt(code),
        string
    });
    const bytes = cw.mg_write(connection, &response[0], response.len);
    if (bytes != response.len) {
        return error.mg_write;
    }
}

pub fn writeHttpHeader(connection: *cw.mg_connection, name: []const u8, value: []const u8) !void
{
    const bufSize = 1024;
    var buf: [bufSize]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{s}: {s}\r\n", .{name, value});
    const bytes = cw.mg_write(connection, &line[0], line.len);
    if (bytes != line.len) {
        return error.mg_write;
    }
}

pub fn writeHttpContentType(connection: *cw.mg_connection, contentType: HttpContentType) !void
{
    const string = switch (contentType) {
        .TextPlain              => "text/plain",
        .TextHtml               => "text/html",
        .ApplicationJson        => "application/json",
        .ApplicationOctetStream => "application/octet-stream",
    };
    try writeHttpHeader(connection, "Content-Type", string);
}

pub fn writeHttpEndHeader(connection: *cw.mg_connection) !void
{
    if (cw.mg_write(connection, "\r\n", 2) != 2) {
        return error.mg_write;
    }
}

const HandlerFunc = fn(connection: *cw.mg_connection, data: ?*c_void) anyerror!void;
const HandlerFuncRaw = fn(connection: ?*cw.mg_connection, data: ?*c_void) callconv(.C) c_int;

fn getHandlerWrapper(comptime handler: HandlerFunc) HandlerFuncRaw
{
    const S = struct {
        fn handlerWrapper(connection: ?*cw.mg_connection, data: ?*c_void) callconv(.C) c_int
        {
            const c = connection orelse {
                std.log.err("null connection object", .{});
                return 500;
            };
            handler(c, data) catch |err| {
                std.log.err("handler failed: {}", .{err});
                writeHttpCode(c, HttpCode._500) catch return 500;
                writeHttpEndHeader(c) catch return 500;
                return 500;
            };

            return 200;
        }
    };
    return S.handlerWrapper;
}

pub fn start(port: u16, ssl: bool, sslCertPath: [:0]const u8, allocator: *std.mem.Allocator) !*cw.mg_context
{
    var callbacks: cw.mg_callbacks = undefined;
    callbacks.begin_request = null;
    callbacks.end_request = null;
    callbacks.log_message = null;
    callbacks.log_access = null;
    callbacks.init_ssl = null;
    callbacks.connection_close = null;
    callbacks.open_file = null;
    callbacks.http_error = null;
    callbacks.init_context = null;
    callbacks.init_thread = null;
    callbacks.exit_context = null;

    const portStr = try std.fmt.allocPrintZ(allocator, "{}s", .{port});
    defer allocator.free(portStr);
    if (!ssl) {
        portStr[portStr.len - 1] = 0;
    }

    var options = std.ArrayList(?*const u8).init(allocator);
    defer options.deinit();
    try options.append(&("listening_ports")[0]);
    try options.append(&portStr[0]);
    if (ssl) {
        try options.append(&("ssl_certificate")[0]);
        try options.append(&sslCertPath[0]);
    }
    try options.append(&("error_log_file")[0]);
    try options.append(&("error.log")[0]);
    try options.append(null);

    const context = cw.mg_start(&callbacks, null, @ptrCast([*c][*c]const u8, options.items));
    if (context) |c| {
        return c;
    }
    else {
        return error.mg_start;
    }
}

pub fn stop(context: *cw.mg_context) void
{
    cw.mg_stop(context);
}

pub fn setRequestHandler(context: *cw.mg_context, comptime uri: [:0]const u8, comptime handler: HandlerFunc, data: ?*c_void) void
{
    const handlerWrapper = getHandlerWrapper(handler);
    cw.mg_set_request_handler(context, uri, handlerWrapper, data);
}

// patching some SSL stuff from civetweb (old SSL function?)
export fn ENGINE_cleanup() void
{
}
