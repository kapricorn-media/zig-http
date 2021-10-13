const std = @import("std");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("memory.h");
    @cInclude("errno.h");
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("netdb.h");
    @cInclude("openssl/crypto.h");
    @cInclude("openssl/x509.h");
    @cInclude("openssl/pem.h");
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/ssl2.h");
    @cInclude("openssl/err.h");
    @cInclude("unistd.h");
});

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

fn sslRead(ssl: *c.SSL, outData: []u8) c_int
{
    return c.SSL_read(ssl, &outData[0], @intCast(c_int, outData.len));
}

fn sslWrite(ssl: *c.SSL, data: []const u8) c_int
{
    return c.SSL_write(ssl, &data[0], @intCast(c_int, data.len));
}

const HttpConnection = struct
{
    useSsl: bool,
    socket: c_int,
    sslContext: *c.SSL_CTX,
    ssl: *c.SSL,

    const Self = @This();

    fn init(comptime useSsl: bool, socket: c_int) !Self
    {
        var self: Self = .{
            .useSsl = useSsl,
            .socket = socket,
            .sslContext = undefined,
            .ssl = undefined,
        };

        if (useSsl) {
            const result = c.OPENSSL_init_ssl(c.OPENSSL_INIT_LOAD_SSL_STRINGS | c.OPENSSL_INIT_LOAD_CRYPTO_STRINGS, null);
            if (result != 1) {
                return error.OPENSSL_init_ssl;
            }

            var clientMethod = c.TLS_client_method();
            self.sslContext = c.SSL_CTX_new(clientMethod) orelse {
                return error.SSL_CTX_new;
            };

            self.ssl = c.SSL_new(self.sslContext) orelse {
                return error.SSL_new;
            };
            if (c.SSL_set_fd(self.ssl, socket) != 1) {
                return error.SSL_set_fd;
            }
            const sslConnectResult = c.SSL_connect(self.ssl);
            if (sslConnectResult != 1) {
                return error.SSL_connect;
            }
        }

        return self;
    }

    fn deinit(self: *Self) void
    {
        const sslShutdownResult = c.SSL_shutdown(self.ssl);
        if (sslShutdownResult != 1) {
            std.log.err("SSL_shutdown failed, {}", .{sslShutdownResult});
        }
        c.SSL_free(self.ssl);
        c.SSL_CTX_free(self.sslContext);
    }

    fn read(self: *const Self, outData: []u8) i64
    {
        if (self.useSsl) {
            return c.SSL_read(self.ssl, &outData[0], @intCast(c_int, outData.len));
        }
        else {
            return c.read(self.socket, &outData[0], outData.len);
        }
    }

    fn write(self: *const Self, data: []const u8) i64
    {
        if (self.useSsl) {
            return c.SSL_write(self.ssl, &data[0], @intCast(c_int, data.len));
        }
        else {
            return c.write(self.socket, &data[0], data.len);
        }
    }
};

pub fn request(
    method: Method,
    comptime useSsl: bool,
    port: i32,
    hostname: [:0]const u8,
    uri: []const u8,
    body: ?[]const u8,
    allocator: *std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    var hint = std.mem.zeroes(c.addrinfo);
    hint.ai_family = c.AF_UNSPEC;
    hint.ai_socktype = c.SOCK_STREAM;
    hint.ai_protocol = 0;
    var addrInfoC: [*c]c.addrinfo = undefined;
    var portBuf: [8]u8 = undefined;
    const portString = try std.fmt.bufPrintZ(&portBuf, "{}", .{port});
    const addrInfoResult = c.getaddrinfo(hostname, portString, &hint, &addrInfoC);
    if (addrInfoResult != 0) {
        std.log.err("getaddrinfo failed, {}", .{addrInfoResult});
        return error.getaddrinfo;
    }

    const addrInfo = addrInfoC.*;
    const socket = c.socket(addrInfo.ai_family, addrInfo.ai_socktype, addrInfo.ai_protocol);
    if (socket == -1) {
        return error.socket;
    }
    defer {
        if (c.close(socket) == -1) {
            std.log.err("close socket failed", .{});
        }
    }

    const connectResult = c.connect(socket, addrInfo.ai_addr, addrInfo.ai_addrlen);
    if (connectResult == -1) {
        return error.connect;
    }

    const conn = try HttpConnection.init(useSsl, socket);

    var buf: [4096]u8 = undefined;
    const headerStart = try std.fmt.bufPrint(
        &buf,
        "{s} {s} HTTP/1.1\r\nHost: {s}:{s}\r\nConnection: close\r\n",
        .{getMethodString(method), uri, portString, hostname}
    );

    const writeHeaderStartBytes = conn.write(headerStart);
    if (writeHeaderStartBytes != headerStart.len) {
        std.log.err("write for headers returned {}, expected {}", .{writeHeaderStartBytes, headerStart.len}); 
        return error.writeHeaderStart;
    }

    // TODO write custom headers

    if (conn.write("\r\n") != 2) {
        return error.writeHeaderEnd;
    }

    if (body) |b| {
        const writeBodyBytes = conn.write(b);
        if (writeBodyBytes != b.len) {
            return error.writeBody;
        }
    }

    const initialCapacity = 4096;
    outData.* = try std.ArrayList(u8).initCapacity(allocator, initialCapacity);
    errdefer outData.deinit();
    while (true) {
        const readBytes = conn.read(&buf);
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
    port: i32,
    hostname: [:0]const u8,
    uri: []const u8,
    allocator: *std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return request(.Get, useSsl, port, hostname, uri, null, allocator, outData, outResponse);
}

pub fn httpGet(
    hostname: [:0]const u8,
    uri: []const u8,
    allocator: *std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return get(false, 80, hostname, uri, allocator, outData, outResponse);
}

pub fn httpsGet(
    hostname: [:0]const u8,
    uri: []const u8,
    allocator: *std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return get(true, 443, hostname, uri, allocator, outData, outResponse);
}

pub fn post(
    comptime useSsl: bool,
    port: i32,
    hostname: [:0]const u8,
    uri: []const u8,
    body: ?[]const u8,
    allocator: *std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return request(.Post, useSsl, port, hostname, uri, body, allocator, outData, outResponse);
}

pub fn httpPost(
    hostname: [:0]const u8,
    uri: []const u8,
    body: ?[]const u8,
    allocator: *std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return post(false, 80, hostname, uri, body, allocator, outData, outResponse);
}

pub fn httpsPost(
    hostname: [:0]const u8,
    uri: []const u8,
    body: ?[]const u8,
    allocator: *std.mem.Allocator,
    outData: *std.ArrayList(u8),
    outResponse: *Response) !void
{
    return post(true, 443, hostname, uri, body, allocator, outData, outResponse);
}
