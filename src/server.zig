const std = @import("std");

const http = @import("http-common");

const bssl = @import("bearssl.zig");

/// Server request callback type.
/// Don't return errors for normal application-specific stuff you can handle thru HTTP codes.
/// Errors should be used only for write failures, tests, or other very special situations. 
pub const CallbackType = fn(
    request: *const Request,
    writer: std.net.Stream.Writer
) anyerror!void;

pub const Request = struct {
    method: http.Method,
    uri: []const u8,
    version: http.Version,
    numHeaders: u32,
    headers: [http.MAX_HEADERS]http.Header,
    body: []const u8,

    const Self = @This();

    fn loadHeaderData(self: *Self, header: []const u8) !void
    {
        var it = std.mem.split(u8, header, "\r\n");

        const first = it.next() orelse return error.NoFirstLine;
        var itFirst = std.mem.split(u8, first, " ");
        const methodString = itFirst.next() orelse return error.NoHttpMethod;
        self.method = http.stringToMethod(methodString) orelse return error.UnknownHttpMethod;
        self.uri = itFirst.next() orelse return error.NoUri;
        const versionString = itFirst.rest();
        self.version = http.stringToVersion(versionString) orelse return error.UnknownHttpVersion;

        try http.readHeaders(self, &it);

        const rest = it.rest();
        if (rest.len != 0) {
            return error.TrailingStuff;
        }
    }
};

pub const HttpsOptions = struct {
    certificatePath: []const u8,
    privateKeyPath: []const u8,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    callback: CallbackType,
    listening: std.atomic.Atomic(bool),
    listenExited: std.atomic.Atomic(bool),
    sockfd: std.os.socket_t,
    listenAddress: std.net.Address,
    buf: []u8,

    const Self = @This();

    pub fn init(
        callback: CallbackType,
        httpsOptions: ?HttpsOptions,
        allocator: std.mem.Allocator) !Self
    {
        var self = Self {
            .allocator = allocator,
            .callback = callback,
            .listening = std.atomic.Atomic(bool).init(false),
            .listenExited = std.atomic.Atomic(bool).init(true),
            .sockfd = undefined,
            .listenAddress = undefined,
            .buf = try allocator.alloc(u8, 1024 * 1024),
        };

        if (httpsOptions) |options| {
            _ = options;
        }

        return self;
    }

    pub fn deinit(self: *Self) void
    {
        if (self.listening.load(.Acquire)) {
            std.log.err("server deinit called without stop", .{});
        }

        self.allocator.free(self.buf);
    }

    pub fn listen(self: *Self, ip: []const u8, port: u16) !void
    {
        self.listenExited.store(false, .Release);
        defer self.listenExited.store(true, .Release);

        // TODO ip6
        const address = try std.net.Address.parseIp4(ip, port);
        const sockFlags = std.os.SOCK.STREAM | std.os.SOCK.CLOEXEC | std.os.SOCK.NONBLOCK;
        const proto = if (address.any.family == std.os.AF.UNIX) @as(u32, 0) else std.os.IPPROTO.TCP;

        self.sockfd = try std.os.socket(address.any.family, sockFlags, proto);
        defer {
            std.os.closeSocket(self.sockfd);
        }
        try std.os.setsockopt(
            self.sockfd,
            std.os.SOL.SOCKET,
            std.os.SO.REUSEADDR, 
            &std.mem.toBytes(@as(c_int, 1))
        );

        var socklen = address.getOsSockLen();
        try std.os.bind(self.sockfd, &address.any, socklen);
        const kernelBacklog = 128;
        try std.os.listen(self.sockfd, kernelBacklog);
        try std.os.getsockname(self.sockfd, &self.listenAddress.any, &socklen);

        self.listening.store(true, .Release);

        while (true) {
            if (!self.listening.load(.Acquire)) {
                break;
            }

            var acceptedAddress: std.net.Address = undefined;
            var addrLen: std.os.socklen_t = @sizeOf(std.net.Address);
            const fd = std.os.accept(
                self.sockfd,
                &acceptedAddress.any,
                &addrLen,
                std.os.SOCK.CLOEXEC | std.os.SOCK.NONBLOCK
            ) catch |err| {
                switch (err) {
                    std.os.AcceptError.WouldBlock => {
                        // sleep? burn CPU?
                    },
                    else => {
                        std.log.err("accept error {}", .{err});
                    },
                }
                continue;
            };

            const stream = std.net.Stream {
                .handle = fd
            };
            defer stream.close();

            self.handleRequest(acceptedAddress, stream) catch |err| {
                std.log.err("handleRequest error {}", .{err});
            };
        }
    }

    pub fn isListening(self: *const Self) bool
    {
        return self.listening.load(.Acquire);
    }

    pub fn stop(self: *Self) void
    {
        if (!self.listening.load(.Acquire)) {
            std.log.err("server stop while not listening", .{});
        }

        self.listening.store(false, .Release);

        // wait for listen to exit
        while (self.listenExited.load(.Acquire)) {}
    }

    fn handleRequest(self: *Self, address: std.net.Address, stream: std.net.Stream) !void
    {
        _ = address;

        var request: Request = undefined;
        var parsedHeader = false;
        var header = std.ArrayList(u8).init(self.allocator);
        defer header.deinit();
        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();
        var contentLength: usize = 0;
        while (true) {
            const n = stream.read(self.buf) catch |err| switch (err) {
                std.os.ReadError.WouldBlock => {
                    continue;
                },
                else => {
                    return err;
                },
            };
            if (n == 0) {
                break;
            }

            const bytes = self.buf[0..n];
            if (!parsedHeader) {
                try header.appendSlice(bytes);
                if (std.mem.indexOf(u8, header.items, "\r\n\r\n")) |ind| {
                    const headerLength = ind + 4;
                    try request.loadHeaderData(header.items[0..headerLength]);
                    if (http.getContentLength(request)) |l| {
                        contentLength = l;
                    } else {
                        std.log.warn("Content-Length missing or invalid, assuming 0", .{});
                    }

                    if (header.items.len > headerLength) {
                        try body.appendSlice(header.items[headerLength..]);
                    }
                    parsedHeader = true;
                }
            }
            if (parsedHeader) {
                if (body.items.len >= contentLength) {
                    request.body = body.items;
                    break;
                }
            }
        }

        const streamWriter = stream.writer();
        self.callback(&request, streamWriter) catch |err| {
            std.log.err("Server request callback error {}", .{err});
            return error.CallbackError;
        };
    }
};

pub fn writeCode(writer: anytype, code: http.Code) !void
{
    const versionString = http.versionToString(http.Version.v1_1);
    try std.fmt.format(
        writer,
        "{s} {} {s}\r\n",
        .{versionString, @enumToInt(code), http.getCodeMessage(code)}
    );
}

pub fn writeHeader(writer: anytype, header: http.Header) !void
{
    try std.fmt.format(writer, "{s}: {s}\r\n", .{header.name, header.value});
}

pub fn writeContentLength(writer: anytype, contentLength: usize) !void
{
    try std.fmt.format(writer, "Content-Length: {}\r\n", .{contentLength});
}

pub fn writeContentType(writer: anytype, contentType: http.ContentType) !void
{
    const string = http.contentTypeToString(contentType);
    try writeHeader(writer, .{.name = "Content-Type", .value = string});
}

pub fn writeEndHeader(writer: anytype) !void
{
    try writer.writeAll("\r\n");
}
