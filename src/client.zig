const std = @import("std");

const bssl = @cImport(@cInclude("bearssl.h"));

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
    if (useSsl) {
        var sc: bssl.br_ssl_client_context = undefined;
        var xc: bssl.br_x509_minimal_context = undefined;
        bssl.br_ssl_client_init_full(&sc, &xc, null, 0);
    }

    var stream = try std.net.tcpConnectToHost(allocator, hostname, port);
    var streamWriter = stream.writer();

    const contentLength = if (body) |b| b.len else 0;
    try std.fmt.format(
        streamWriter,
        "{s} {s} HTTP/1.1\r\nHost: {s}:{}\r\nConnection: close\r\nContent-Length: {}\r\n",
        .{getMethodString(method), uri, hostname, port, contentLength}
    );

    if (headers) |hs| {
        for (hs) |h| {
            try std.fmt.format(streamWriter, "{s}: {s}\r\n", .{h.name, h.value});
        }
    }

    if ((try stream.write("\r\n")) != 2) {
        return error.writeHeaderEnd;
    }

    if (body) |b| {
        if ((try stream.write(b)) != b.len) {
            return error.writeBody;
        }
    }

    const initialCapacity = 4096;
    outData.* = try std.ArrayList(u8).initCapacity(allocator, initialCapacity);
    errdefer outData.deinit();
    var buf: [4096]u8 = undefined;
    while (true) {
        const readBytes = try stream.read(&buf);
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
