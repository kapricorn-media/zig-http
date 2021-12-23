const std = @import("std");

const bssl = @import("bearssl");
const http = @import("http-common");

const certs = @import("certs.zig");
const net_io = @import("net_io.zig");

pub const Response = struct
{
    version: http.Version,
    code: http.Code,
    message: []const u8,
    numHeaders: u32,
    headers: [http.MAX_HEADERS]http.Header,
    body: []const u8,

    const Self = @This();

    /// For string formatting, easy printing/debugging.
    pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void
    {
        _ = fmt; _ = options;
        try std.fmt.format(
            writer,
            "[version={} code={} message=\"{s}\" body.len={}]",
            .{self.version, self.code, self.message, self.body.len}
        );
    }

    fn load(self: *Self, data: []const u8) !void
    {
        var it = std.mem.split(u8, data, "\r\n");

        const first = it.next() orelse {
            return error.NoFirstLine;
        };
        var itFirst = std.mem.split(u8, first, " ");
        const versionString = itFirst.next() orelse return error.NoVersion;
        self.version = http.stringToVersion(versionString) orelse return error.UnknownVersion;
        const codeString = itFirst.next() orelse return error.NoCode;
        const codeU32 = try std.fmt.parseUnsigned(u32, codeString, 10);
        self.code = http.intToCode(codeU32) orelse return error.UnknownCode;
        self.message = itFirst.rest();

        try http.readHeaders(self, &it);

        self.body = it.rest();
    }
};

const HttpsState = struct {
    rootCaList: certs.RootCaList,
    sslContext: bssl.c.br_ssl_client_context,
    x509Context: bssl.c.br_x509_minimal_context,
    buf: []u8,

    const Self = @This();

    fn load(self: *Self, hostname: [:0]const u8, allocator: std.mem.Allocator) !void
    {
        try self.rootCaList.load(allocator);
        self.buf = try allocator.alloc(u8, bssl.c.BR_SSL_BUFSIZE_BIDI);

        bssl.c.br_ssl_client_init_full(
            &self.sslContext, &self.x509Context,
            &self.rootCaList.list.items[0], self.rootCaList.list.items.len
        );
        bssl.c.br_ssl_engine_set_buffer(&self.sslContext.eng, &self.buf[0], self.buf.len, 1);

        const result = bssl.c.br_ssl_client_reset(&self.sslContext, hostname, 0);
        if (result != 1) {
            return error.br_ssl_client_reset;
        }
    }

    fn deinit(self: *Self, allocator: std.mem.Allocator) void
    {
        allocator.free(self.buf);
        self.rootCaList.deinit(allocator);
    }
};

pub fn request(
    method: http.Method,
    https: bool,
    port: u16,
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const http.Header,
    body: ?[]const u8,
    allocator: std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    var tcpStream = try std.net.tcpConnectToHost(allocator, hostname, port);

    var httpsState: ?*HttpsState = if (https) try allocator.create(HttpsState) else null;
    defer if (httpsState) |state| allocator.destroy(state);

    if (httpsState) |state| try state.load(hostname, allocator);
    defer if (httpsState) |state| state.deinit(allocator);

    var engine = if (httpsState) |_| &httpsState.?.sslContext.eng else null;
    const stream = net_io.Stream.init(tcpStream, engine);
    defer stream.close();

    var writer = stream.writer();
    const contentLength = if (body) |b| b.len else 0;
    try std.fmt.format(
        writer,
        "{s} {s} HTTP/1.1\r\nHost: {s}:{}\r\nConnection: close\r\nContent-Length: {}\r\n",
        .{http.methodToString(method), uri, hostname, port, contentLength}
    );

    if (headers) |hs| {
        for (hs) |h| {
            try std.fmt.format(writer, "{s}: {s}\r\n", .{h.name, h.value});
        }
    }

    if ((try writer.write("\r\n")) != 2) {
        return error.writeHeaderEnd;
    }

    if (body) |b| {
        if ((try writer.write(b)) != b.len) {
            return error.writeBody;
        }
    }

    try stream.flush();

    var reader = stream.reader();
    const initialCapacity = 4096;
    outData.* = try std.ArrayList(u8).initCapacity(allocator, initialCapacity);
    errdefer outData.deinit();
    var buf: [4096]u8 = undefined;
    while (true) {
        const readBytes = try reader.read(&buf);
        if (readBytes < 0) {
            return error.readResponse;
        }
        if (readBytes == 0) {
            break;
        }

        try outData.appendSlice(buf[0..@intCast(usize, readBytes)]);
    }

    try outResponse.load(outData.items);
}

pub fn get(
    https: bool,
    port: u16,
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const http.Header,
    allocator: std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return request(.Get, https, port, hostname, uri, headers, null, allocator, outData, outResponse);
}

pub fn httpGet(
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const http.Header,
    allocator: std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return get(false, 80, hostname, uri, headers, allocator, outData, outResponse);
}

pub fn httpsGet(
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const http.Header,
    allocator: std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return get(true, 443, hostname, uri, headers, allocator, outData, outResponse);
}

pub fn post(
    https: bool,
    port: u16,
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const http.Header,
    body: ?[]const u8,
    allocator: std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return request(.Post, https, port, hostname, uri, headers, body, allocator, outData, outResponse);
}

pub fn httpPost(
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const http.Header,
    body: ?[]const u8,
    allocator: std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return post(false, 80, hostname, uri, headers, body, allocator, outData, outResponse);
}

pub fn httpsPost(
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const http.Header,
    body: ?[]const u8,
    allocator: std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return post(true, 443, hostname, uri, headers, body, allocator, outData, outResponse);
}
