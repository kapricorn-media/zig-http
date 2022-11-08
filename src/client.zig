const builtin = @import("builtin");
const std = @import("std");

const bssl = @import("bearssl");
const http = @import("http-common");

const net_io = @import("net_io.zig");
const macos_certs = @cImport(@cInclude("macos_certs.h"));

var _anchorsOverride: ?bssl.crt.Anchors = null;

pub fn overrideRootCaList(certFileData: []const u8, allocator: std.mem.Allocator) !void
{
    _anchorsOverride = try bssl.crt.Anchors.init(certFileData, allocator);
}

pub fn freeOverrideRootCaList(allocator: std.mem.Allocator) void
{
    if (_anchorsOverride) |anchors| {
        anchors.deinit(allocator);
        _anchorsOverride = null;
    }
}

pub const RequestError = error {
    ConnectError,
    AllocError,
    HttpsInitError,
    HttpsError,
    WriteError,
    ReadError,
    ResponseError,
};

pub const Response = struct
{
    allocator: std.mem.Allocator,
    version: http.Version,
    code: http.Code,
    message: []const u8,
    headers: []http.Header,
    body: []const u8,

    const Self = @This();

    pub fn init(data: []const u8, allocator: std.mem.Allocator) !Self
    {
        var self = Self {
            .allocator = allocator,
            .version = undefined,
            .code = undefined,
            .message = &.{},
            .headers = &.{},
            .body = &.{},
        };
        errdefer self.deinit();

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
        const message = itFirst.rest();
        if (message.len > 0) {
            self.message = try allocator.dupe(u8, message);
        }

        try http.readHeaders(&self, &it, allocator);

        const contentLengthString = http.getHeader(self, "Content-Length");
        if (contentLengthString) |cl| {
            const contentLength = try std.fmt.parseUnsigned(u64, cl, 10);
            const body = it.rest();
            if (contentLength != body.len) {
                return error.BadContentLength;
            }
            if (body.len > 0) {
                self.body = try allocator.dupe(u8, body);
            }
        } else {
            const transferEncoding = http.getHeader(self, "Transfer-Encoding");
            if (transferEncoding) |te| {
                if (std.mem.eql(u8, te, "chunked")) {
                    var body = std.ArrayList(u8).init(allocator);
                    defer body.deinit();
                    var chunk = it.rest();
                    var chunkIt = std.mem.split(u8, chunk, "\r\n");
                    while (true) {
                        const chunkLenStr = chunkIt.next() orelse return error.NoChunkLength;
                        const chunkLen = try std.fmt.parseUnsigned(u64, chunkLenStr, 16);
                        const chunkData = chunkIt.next() orelse return error.NoChunkBody;
                        if (chunkData.len != chunkLen) {
                            return error.BadChunkLength;
                        }
                        if (chunkLen == 0) {
                            break;
                        }
                        try body.appendSlice(chunkData);
                    }
                    const chunkRest = chunkIt.rest();
                    if (chunkRest.len != 0) {
                        return error.ChunkTrailingData;
                    }
                    if (body.items.len > 0) {
                        self.body = body.toOwnedSlice();
                    }
                } else {
                    return error.UnsupportedTransferEncoding;
                }
            } else {
                // no content length or transfer encoding. leave body as default (empty).
            }
        }

        return self;
    }

    pub fn deinit(self: Self) void
    {
        if (self.message.len > 0) {
            self.allocator.free(self.message);
        }
        if (self.headers.len > 0) {
            for (self.headers) |h| {
                if (h.name.len > 0) {
                    self.allocator.free(h.name);
                }
                if (h.value.len > 0) {
                    self.allocator.free(h.value);
                }
            }
            self.allocator.free(self.headers);
        }
        if (self.body.len > 0) {
            self.allocator.free(self.body);
        }
    }

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
};

pub fn request(
    method: http.Method,
    https: bool,
    port: u16,
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const http.Header,
    body: ?[]const u8,
    allocator: std.mem.Allocator) RequestError!Response
{
    var tcpStream = std.net.tcpConnectToHost(allocator, hostname, port) catch |err| {
        std.log.err("tcpConnectToHost failed {}", .{err});
        return RequestError.ConnectError;
    };
    defer tcpStream.close();

    var httpsState: ?*HttpsState = blk: {
        if (https) {
            break :blk allocator.create(HttpsState) catch {
                return RequestError.AllocError;
            };
        } else {
            break :blk null;
        }
    };
    defer if (httpsState) |state| allocator.destroy(state);
    if (httpsState) |state| state.load(hostname, allocator) catch |err| {
        std.log.err("HttpsState load failed {}", .{err});
        return RequestError.HttpsInitError;
    };
    defer if (httpsState) |state| state.deinit(allocator);

    var engine = if (httpsState) |_| &httpsState.?.sslContext.eng else null;
    var stream = net_io.Stream.init(tcpStream.handle, engine);

    const contentLength = if (body) |b| b.len else 0;
    std.fmt.format(
        stream,
        "{s} {s} HTTP/1.1\r\nHost: {s}:{}\r\nConnection: close\r\nContent-Length: {}\r\n",
        .{http.methodToString(method), uri, hostname, port, contentLength}
    ) catch |err| switch (err) {
        error.BsslError => return RequestError.HttpsError,
        else => return RequestError.WriteError,
    };

    if (headers) |hs| {
        for (hs) |h| {
            std.fmt.format(stream, "{s}: {s}\r\n", .{h.name, h.value}) catch |err| switch (err) {
                error.BsslError => return RequestError.HttpsError,
                else => return RequestError.WriteError,
            };
        }
    }

    stream.writeAll("\r\n") catch |err| switch (err) {
        error.BsslError => return RequestError.HttpsError,
        else => return RequestError.WriteError,
    };

    if (body) |b| {
        stream.writeAll(b) catch |err| switch (err) {
            error.BsslError => return RequestError.HttpsError,
            else => return RequestError.WriteError,
        };
    }

    stream.flush() catch return RequestError.WriteError;

    const initialCapacity = 4096;
    var data = std.ArrayList(u8).initCapacity(allocator, initialCapacity) catch |err| {
        std.log.err("ArrayList initCapacity error {}", .{err});
        return RequestError.AllocError;
    };
    defer data.deinit();
    var buf: [4096]u8 = undefined;
    while (true) {
        const readBytes = stream.read(&buf) catch |err| switch (err) {
            error.BsslError => return RequestError.HttpsError,
            else => return RequestError.ReadError,
        };
        if (readBytes == 0) {
            break;
        }

        data.appendSlice(buf[0..@intCast(usize, readBytes)]) catch {
            return RequestError.AllocError;
        };
    }

    return Response.init(data.items, allocator) catch return RequestError.ResponseError;
}

pub fn get(
    https: bool,
    port: u16,
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const http.Header,
    allocator: std.mem.Allocator) RequestError!Response
{
    return request(.Get, https, port, hostname, uri, headers, null, allocator);
}

pub fn httpGet(
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const http.Header,
    allocator: std.mem.Allocator) RequestError!Response
{
    return get(false, 80, hostname, uri, headers, allocator);
}

pub fn httpsGet(
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const http.Header,
    allocator: std.mem.Allocator) RequestError!Response
{
    return get(true, 443, hostname, uri, headers, allocator);
}

pub fn post(
    https: bool,
    port: u16,
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const http.Header,
    body: ?[]const u8,
    allocator: std.mem.Allocator) RequestError!Response
{
    return request(.Post, https, port, hostname, uri, headers, body, allocator);
}

pub fn httpPost(
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const http.Header,
    body: ?[]const u8,
    allocator: std.mem.Allocator) RequestError!Response
{
    return post(false, 80, hostname, uri, headers, body, allocator);
}

pub fn httpsPost(
    hostname: [:0]const u8,
    uri: []const u8,
    headers: ?[]const http.Header,
    body: ?[]const u8,
    allocator: std.mem.Allocator) RequestError!Response
{
    return post(true, 443, hostname, uri, headers, body, allocator);
}

const HttpsState = struct {
    anchors: ?bssl.crt.Anchors,
    rawAnchors: []const bssl.c.br_x509_trust_anchor,
    sslContext: bssl.c.br_ssl_client_context,
    x509Context: bssl.c.br_x509_minimal_context,
    buf: []u8,

    const Self = @This();

    fn load(self: *Self, hostname: [:0]const u8, allocator: std.mem.Allocator) !void
    {
        var anchors: *const bssl.crt.Anchors = undefined;
        if (_anchorsOverride) |_| {
            self.anchors = null;
            anchors = &_anchorsOverride.?;
        } else {
            self.anchors = try loadAnchorsFromOs(allocator);
            anchors = &self.anchors.?;
        }
        errdefer if (self.anchors) |a| a.deinit(allocator);
        self.rawAnchors = try anchors.getRawAnchors(allocator);
        errdefer allocator.free(self.rawAnchors);
        self.buf = try allocator.alloc(u8, bssl.c.BR_SSL_BUFSIZE_BIDI);
        errdefer allocator.free(self.buf);

        bssl.c.br_ssl_client_init_full(
            &self.sslContext, &self.x509Context,
            &self.rawAnchors[0], self.rawAnchors.len
        );
        bssl.c.br_ssl_engine_set_buffer(&self.sslContext.eng, &self.buf[0], self.buf.len, 1);
        const result = bssl.c.br_ssl_client_reset(&self.sslContext, @ptrCast([*c]const u8, hostname), 0);
        if (result != 1) {
            return error.br_ssl_client_reset;
        }
    }

    fn deinit(self: *Self, allocator: std.mem.Allocator) void
    {
        allocator.free(self.rawAnchors);
        allocator.free(self.buf);
        if (self.anchors) |anchors| {
            anchors.deinit(allocator);
        }
    }
};

// TODO maybe move this to zig-bearssl? eh...
const MacosCertState = struct {
    allocator: std.mem.Allocator,
    anchors: std.ArrayList(bssl.crt.Anchor),
    success: bool,
};

fn macosCertCallback(userData: ?*anyopaque, bytes: [*c]const u8, len: c_int) callconv(.C) void
{
    var state = @ptrCast(*MacosCertState, @alignCast(@alignOf(*MacosCertState), userData));
    var anchor = state.anchors.addOne() catch {
        state.success = false;
        return;
    };
    const slice = bytes[0..@intCast(usize, len)];
    anchor.* = bssl.crt.Anchor.init(slice, state.allocator) catch {
        state.success = false;
        return;
    };
}

fn loadAnchorsFromOs(allocator: std.mem.Allocator) !bssl.crt.Anchors
{
    switch (builtin.target.os.tag) {
        .linux => {
            const certsPath = "/etc/ssl/certs/ca-certificates.crt";
            const file = try std.fs.openFileAbsolute(certsPath, .{});
            defer file.close();
            const fileData = try file.readToEndAlloc(allocator, 1024 * 1024 * 1024);
            defer allocator.free(fileData);
            return bssl.crt.Anchors.init(fileData, allocator);
        },
        .macos => {
            var state = MacosCertState {
                .allocator = allocator,
                .anchors = std.ArrayList(bssl.crt.Anchor).init(allocator),
                .success = true,
            };
            defer state.anchors.deinit();

            if (macos_certs.getRootCaCerts(&state, macosCertCallback) != 0) {
                return error.macosGetRootCaCerts;
            }
            if (!state.success) {
                return error.macosGetRootCaCertsCallback;
            }

            var anchors = bssl.crt.Anchors {
                .anchors = state.anchors.toOwnedSlice(),
            };
            return anchors;
        },
        else => {
            @compileError("Unsupported OS");
        },
    }
}
