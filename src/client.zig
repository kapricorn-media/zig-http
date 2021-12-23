const std = @import("std");

const bssl = @import("bearssl");
const http = @import("http-common");

const certs = @import("certs.zig");

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

fn netSslRead(userData: ?*anyopaque, data: ?[*]u8, len: usize) callconv(.C) c_int
{
    const d = data orelse return -1;
    var stream = @ptrCast(*std.net.Stream, @alignCast(@alignOf(*std.net.Stream), userData));
    const buf = d[0..len];

    const bytes = stream.read(buf) catch |err| {
        std.log.err("net stream read error {}", .{err});
        return -1;
    };
    if (bytes == 0) {
        return -1;
    } else {
        return @intCast(c_int, bytes);
    }
}

fn netSslWrite(userData: ?*anyopaque, data: ?[*]const u8, len: usize) callconv(.C) c_int
{
    const d = data orelse return 0;
    var stream = @ptrCast(*std.net.Stream, @alignCast(@alignOf(*std.net.Stream), userData));
    const bytes = stream.write(d[0..len]) catch |err| {
        std.log.err("net stream write error {}", .{err});
        return -1;
    };
    return @intCast(c_int, bytes);
}

const NetInterface = struct {
    stream: std.net.Stream,
    https: bool,
    rootCaList: certs.RootCaList,
    sslContext: bssl.c.br_ssl_client_context,
    x509Context: bssl.c.br_x509_minimal_context,
    sslIoContext: bssl.c.br_sslio_context,
    sslIoBuf: []u8,

    const Self = @This();

    fn load(self: *Self, hostname: [:0]const u8, stream: std.net.Stream, https: bool, allocator: std.mem.Allocator) !void
    {
        self.stream = stream;
        self.https = https;
        if (https) {
            try self.rootCaList.load(allocator);
            self.sslIoBuf = try allocator.alloc(u8, bssl.c.BR_SSL_BUFSIZE_BIDI);

            bssl.c.br_ssl_client_init_full(
                &self.sslContext, &self.x509Context,
                &self.rootCaList.list.items[0], self.rootCaList.list.items.len
            );
            bssl.c.br_ssl_engine_set_buffer(
                &self.sslContext.eng,
                &self.sslIoBuf[0], self.sslIoBuf.len, 1
            );

            const result = bssl.c.br_ssl_client_reset(&self.sslContext, hostname, 0);
            if (result != 1) {
                return error.br_ssl_client_reset;
            }

            bssl.c.br_sslio_init(
                &self.sslIoContext, &self.sslContext.eng,
                netSslRead, &self.stream,
                netSslWrite, &self.stream
            );
        }
    }

    fn deinit(self: *Self, allocator: std.mem.Allocator) void
    {
        if (self.https) {
            if (bssl.c.br_sslio_close(&self.sslIoContext) != 0) {
                std.log.err("br_sslio_close failed", .{});
            }
            allocator.free(self.sslIoBuf);
            self.rootCaList.deinit(allocator);
        }
    }

    fn reader(self: *Self) std.io.Reader(*Self, anyerror, read)
    {
        return .{ .context = self };
    }

    fn writer(self: *Self) std.io.Writer(*Self, anyerror, write)
    {
        return .{ .context = self };
    }

    fn read(self: *Self, buffer: []u8) anyerror!usize
    {
        if (self.https) {
            const result = bssl.c.br_sslio_read(&self.sslIoContext, &buffer[0], buffer.len);
            if (result < 0) {
                const engState = bssl.c.br_ssl_engine_current_state(&self.sslContext.eng);
                const err = bssl.c.br_ssl_engine_last_error(&self.sslContext.eng);
                if (engState == bssl.c.BR_SSL_CLOSED and (err == bssl.c.BR_ERR_OK or err == bssl.c.BR_ERR_IO)) {
                    // TODO why BR_ERR_IO?
                    return 0;
                } else {
                    return error.bsslReadFail;
                }
            } else {
                return @intCast(usize, result);
            }
        } else {
            return try self.stream.read(buffer);
        }
    }

    fn write(self: *Self, buffer: []const u8) anyerror!usize
    {
        if (self.https) {
            const result = bssl.c.br_sslio_write(&self.sslIoContext, &buffer[0], buffer.len);
            if (result < 0) {
                const err = bssl.c.br_ssl_engine_last_error(&self.sslContext.eng);
                std.log.err("br_sslio_write fail, engine err {}", .{err});
                return error.bsslWriteFail;
            } else {
                return @intCast(usize, result);
            }
        } else {
            return try self.stream.write(buffer);
        }
    }

    fn flush(self: *Self) !void
    {
        if (self.https) {
            if (bssl.c.br_sslio_flush(&self.sslIoContext) != 0) {
                return error.br_sslio_flush;
            }
        }
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
    var stream = try std.net.tcpConnectToHost(allocator, hostname, port);
    var netInterface: *NetInterface = try allocator.create(NetInterface);
    defer allocator.destroy(netInterface);
    try netInterface.load(hostname, stream, https, allocator);
    defer netInterface.deinit(allocator);

    var netWriter = netInterface.writer();
    const contentLength = if (body) |b| b.len else 0;
    try std.fmt.format(
        netWriter,
        "{s} {s} HTTP/1.1\r\nHost: {s}:{}\r\nConnection: close\r\nContent-Length: {}\r\n",
        .{http.methodToString(method), uri, hostname, port, contentLength}
    );

    if (headers) |hs| {
        for (hs) |h| {
            try std.fmt.format(netWriter, "{s}: {s}\r\n", .{h.name, h.value});
        }
    }

    if ((try netWriter.write("\r\n")) != 2) {
        return error.writeHeaderEnd;
    }

    if (body) |b| {
        if ((try netWriter.write(b)) != b.len) {
            return error.writeBody;
        }
    }

    try netInterface.flush();

    var netReader = netInterface.reader();
    const initialCapacity = 4096;
    outData.* = try std.ArrayList(u8).initCapacity(allocator, initialCapacity);
    errdefer outData.deinit();
    var buf: [4096]u8 = undefined;
    while (true) {
        const readBytes = try netReader.read(&buf);
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
