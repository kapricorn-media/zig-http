const std = @import("std");

const bssl = @import("bearssl.zig");
const certs = @import("certs.zig");

pub const HttpVersion = enum
{
    Http1_0,
    Http1_1,
    Unknown,
};

pub const Method = enum
{
    Get,
    Post,
};

pub const Header = struct
{
    name: []const u8,
    value: []const u8,
};

pub const Response = struct
{
    version: HttpVersion,
    code: u32,
    message: []const u8,
    numHeaders: u32,
    headers: [MAX_HEADERS]Header,
    body: []const u8,

    const MAX_HEADERS = 8 * 1024;
    const Self = @This();

    fn load(self: *Self, data: []const u8) !void
    {
        var it = std.mem.split(u8, data, "\r\n");
        const first = it.next() orelse {
            return error.NoFirstLine;
        };

        var itFirst = std.mem.split(u8, first, " ");
        const versionString = itFirst.next() orelse {
            return error.NoHttpVersion;
        };
        self.version = stringToHttpVersion(versionString);
        if (self.version == .Unknown) {
            return error.UnknownHttpVersion;
        }
        const codeString = itFirst.next() orelse {
            return error.NoHttpCode;
        };
        self.code = try std.fmt.parseUnsigned(u32, codeString, 10);
        self.message = itFirst.rest();

        self.numHeaders = 0;
        while (true) {
            const header = it.next() orelse {
                return error.UnexpectedEndOfHeader;
            };
            if (header.len == 0) {
                break;
            }

            var itHeader = std.mem.split(u8, header, ":");
            self.headers[self.numHeaders].name = itHeader.next() orelse {
                return error.HeaderMissingName;
            };
            const v = itHeader.next() orelse {
                return error.HeaderMissingValue;
            };
            self.headers[self.numHeaders].value = std.mem.trimLeft(u8, v, " ");
            self.numHeaders += 1;
        }

        self.body = it.rest();
    }

    pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void
    {
        _ = fmt; _ = options;
        try std.fmt.format(
            writer,
            "[version={} code={} message=\"{s}\" body.len={}]",
            .{self.version, self.code, self.message, self.body.len}
        );
    }
};

fn stringToHttpVersion(string: []const u8) HttpVersion
{
    if (std.mem.eql(u8, string, "HTTP/1.1")) {
        return .Http1_1;
    }
    else if (std.mem.eql(u8, string, "HTTP/1.0")) {
        return .Http1_0;
    }
    else {
        return .Unknown;
    }
}

fn getMethodString(method: Method) []const u8
{
    switch (method) {
        .Get => return "GET",
        .Post => return "POST",
    }
}

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
    useSsl: bool,
    rootCaList: certs.RootCaList,
    sslContext: bssl.br_ssl_client_context,
    x509Context: bssl.br_x509_minimal_context,
    sslIoContext: bssl.br_sslio_context,
    sslIoBuf: []u8,

    const Self = @This();

    fn load(self: *Self, hostname: [:0]const u8, stream: std.net.Stream, useSsl: bool, allocator: std.mem.Allocator) !void
    {
        self.stream = stream;
        self.useSsl = useSsl;
        if (useSsl) {
            try self.rootCaList.load(allocator);
            self.sslIoBuf = try allocator.alloc(u8, bssl.BR_SSL_BUFSIZE_BIDI);

            bssl.br_ssl_client_init_full(
                &self.sslContext, &self.x509Context,
                &self.rootCaList.list.items[0], self.rootCaList.list.items.len
            );
            bssl.br_ssl_engine_set_buffer(
                &self.sslContext.eng,
                &self.sslIoBuf[0], self.sslIoBuf.len, 1
            );

            const result = bssl.br_ssl_client_reset(&self.sslContext, hostname, 0);
            if (result != 1) {
                return error.br_ssl_client_reset;
            }

            bssl.br_sslio_init(
                &self.sslIoContext, &self.sslContext.eng,
                netSslRead, &self.stream,
                netSslWrite, &self.stream
            );
        }
    }

    fn deinit(self: *Self, allocator: std.mem.Allocator) void
    {
        if (self.useSsl) {
            if (bssl.br_sslio_close(&self.sslIoContext) != 0) {
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
        if (self.useSsl) {
            const result = bssl.br_sslio_read(&self.sslIoContext, &buffer[0], buffer.len);
            if (result < 0) {
                const engState = bssl.br_ssl_engine_current_state(&self.sslContext.eng);
                const err = bssl.br_ssl_engine_last_error(&self.sslContext.eng);
                if (engState == bssl.BR_SSL_CLOSED and (err == bssl.BR_ERR_OK or err == bssl.BR_ERR_IO)) {
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
        if (self.useSsl) {
            const result = bssl.br_sslio_write(&self.sslIoContext, &buffer[0], buffer.len);
            if (result < 0) {
                const err = bssl.br_ssl_engine_last_error(&self.sslContext.eng);
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
        if (self.useSsl) {
            if (bssl.br_sslio_flush(&self.sslIoContext) != 0) {
                return error.br_sslio_flush;
            }
        }
    }
};

pub fn request(
    method: Method,
    comptime useSsl: bool,
    port: u16,
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const Header,
    body: ?[]const u8,
    allocator: std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    var stream = try std.net.tcpConnectToHost(allocator, hostname, port);
    var netInterface: *NetInterface = try allocator.create(NetInterface);
    defer allocator.destroy(netInterface);
    try netInterface.load(hostname, stream, useSsl, allocator);
    defer netInterface.deinit(allocator);

    var netWriter = netInterface.writer();
    const contentLength = if (body) |b| b.len else 0;
    try std.fmt.format(
        netWriter,
        "{s} {s} HTTP/1.1\r\nHost: {s}:{}\r\nConnection: close\r\nContent-Length: {}\r\n",
        .{getMethodString(method), uri, hostname, port, contentLength}
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
    comptime useSsl: bool,
    port: u16,
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const Header,
    allocator: std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return request(.Get, useSsl, port, hostname, uri, headers, null, allocator, outData, outResponse);
}

pub fn httpGet(
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const Header,
    allocator: std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return get(false, 80, hostname, uri, headers, allocator, outData, outResponse);
}

pub fn httpsGet(
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const Header,
    allocator: std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return get(true, 443, hostname, uri, headers, allocator, outData, outResponse);
}

pub fn post(
    comptime useSsl: bool,
    port: u16,
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const Header,
    body: ?[]const u8,
    allocator: std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return request(.Post, useSsl, port, hostname, uri, headers, body, allocator, outData, outResponse);
}

pub fn httpPost(
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const Header,
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
    headers: ?[]const Header,
    body: ?[]const u8,
    allocator: std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return post(true, 443, hostname, uri, headers, body, allocator, outData, outResponse);
}
