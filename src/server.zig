const std = @import("std");

const bssl = @import("bearssl");
const http = @import("http-common");

const net_io = @import("net_io.zig");

const localhost = @import("localhost.zig");

pub const Stream = net_io.Stream;

// pub const Reader = net_io.Stream.Reader;
// pub const Writer = net_io.Stream.Writer;

/// Server request callback type.
/// Don't return errors for normal application-specific stuff you can handle thru HTTP codes.
/// Errors should be used only for write failures, tests, or other very special situations. 
pub const CallbackType = fn(request: *const Request, stream: net_io.Stream) anyerror!void;

pub const Request = struct {
    method: http.Method,
    uri: []const u8,
    version: http.Version,
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
            "[method={} uri={s} version={} numHeaders={} body.len={}]",
            .{self.method, self.uri, self.version, self.numHeaders, self.body.len}
        );
    }

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
    certChainFileData: []const u8,
    privateKeyFileData: []const u8,
};

const HttpsState = struct {
    chain: std.ArrayList(bssl.c.br_x509_certificate),
    skeyContext: bssl.c.br_skey_decoder_context,
    privateKey: *const bssl.c.br_rsa_private_key,
    buf: []u8,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    callback: CallbackType,
    listening: std.atomic.Atomic(bool),
    listenExited: std.atomic.Atomic(bool),
    sockfd: std.os.socket_t,
    listenAddress: std.net.Address,
    buf: []u8,
    httpsState: ?HttpsState,

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
            .httpsState = null,
        };
        errdefer allocator.free(self.buf);

        if (httpsOptions) |options| {
            self.httpsState = HttpsState {
                .chain = std.ArrayList(bssl.c.br_x509_certificate).init(allocator),
                .skeyContext = undefined,
                .privateKey = undefined,
                .buf = try allocator.alloc(u8, bssl.c.BR_SSL_BUFSIZE_BIDI),
            };

            var initState = HttpsInitState {
                .allocator = allocator,
                .chain = &self.httpsState.?.chain,
                .skeyContext = &self.httpsState.?.skeyContext,
                .privateKeySet = false,
                .privateKey = &self.httpsState.?.privateKey,
            };

            try bssl.decodePem(
                options.certChainFileData,
                *HttpsInitState, &initState, pemCallbackCertChain,
                allocator
            );
            if (initState.chain.items.len == 0) {
                return error.NoCertificateChain;
            }

            try bssl.decodePem(
                options.privateKeyFileData,
                *HttpsInitState, &initState, pemCallbackPrivateKey,
                allocator
            );
            if (!initState.privateKeySet) {
                return error.NoPrivateKey;
            }
        }

        return self;
    }

    pub fn deinit(self: *Self) void
    {
        if (self.listening.load(.Acquire)) {
            std.log.err("server deinit called without stop", .{});
        }

        self.allocator.free(self.buf);
        if (self.httpsState) |state| {
            for (state.chain.items) |chain| {
                const bytes = chain.data[0..chain.data_len];
                self.allocator.free(bytes);
            }
            state.chain.deinit();
            self.allocator.free(state.buf);
        }
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
            defer std.os.closeSocket(fd);

            var context: bssl.c.br_ssl_server_context = undefined;
            var engine: ?*bssl.c.br_ssl_engine_context = null;
            if (self.httpsState) |_| {
                // bssl.c.br_ssl_server_init_full_rsa(
                //     &context,
                //     &self.httpsState.?.chain.items[0], self.httpsState.?.chain.items.len,
                //     self.httpsState.?.privateKey);
                bssl.c.br_ssl_server_init_full_rsa(
                    &context,
                    &self.httpsState.?.chain.items[0], self.httpsState.?.chain.items.len,
                    &localhost.RSA);
                // bssl.c.br_ssl_server_init_full_rsa(
                //     &context,
                //     &localhost.CHAIN[0], localhost.CHAIN.len,
                //     &localhost.RSA);
                bssl.c.br_ssl_engine_set_buffer(
                    &context.eng,
                    &self.httpsState.?.buf[0], self.httpsState.?.buf.len, 1);
                if (bssl.c.br_ssl_server_reset(&context) != 1) {
                    return error.br_ssl_server_reset;
                }

                engine = &context.eng;
            }

            var stream = net_io.Stream.init(std.net.Stream {.handle = fd}, engine);
            defer stream.closeHttpsIfOpen() catch {};

            self.handleRequest(acceptedAddress, stream) catch |err| {
                std.log.warn("handleRequest error {}", .{err});
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

    fn handleRequest(self: *Self, address: std.net.Address, stream: net_io.Stream) !void
    {
        _ = address;

        std.log.warn("handleRequest", .{});
        defer std.log.warn("handleRequest done", .{});
        var request: Request = undefined;
        var parsedHeader = false;
        var header = std.ArrayList(u8).init(self.allocator);
        defer header.deinit();
        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();
        var contentLength: usize = 0;
        while (true) {
            // std.log.warn("before read", .{});
            const n = stream.read(self.buf) catch |err| switch (err) {
                std.os.ReadError.WouldBlock => {
                    continue;
                },
                else => {
                    return err;
                },
            };
            std.log.warn("n {}", .{n});
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

        if (!parsedHeader) {
            return error.NoParsedHeader;
        }
        if (body.items.len != contentLength) {
            return error.ContentLengthMismatch;
        }

        self.callback(&request, stream) catch |err| {
            return err;
        };

        try stream.flush();
    }
};

pub fn writeCode(stream: net_io.Stream, code: http.Code) !void
{
    const versionString = http.versionToString(http.Version.v1_1);
    try std.fmt.format(
        stream,
        "{s} {} {s}\r\n",
        .{versionString, @enumToInt(code), http.getCodeMessage(code)}
    );
}

pub fn writeHeader(stream: net_io.Stream, header: http.Header) !void
{
    try std.fmt.format(stream, "{s}: {s}\r\n", .{header.name, header.value});
}

pub fn writeContentLength(stream: net_io.Stream, contentLength: usize) !void
{
    try std.fmt.format(stream, "Content-Length: {}\r\n", .{contentLength});
}

pub fn writeContentType(stream: net_io.Stream, contentType: http.ContentType) !void
{
    const string = http.contentTypeToString(contentType);
    try writeHeader(stream, .{.name = "Content-Type", .value = string});
}

pub fn writeEndHeader(stream: net_io.Stream) !void
{
    try stream.writeAll("\r\n");
}

const HttpsInitState = struct {
    allocator: std.mem.Allocator,
    chain: *std.ArrayList(bssl.c.br_x509_certificate),
    skeyContext: *bssl.c.br_skey_decoder_context,
    privateKeySet: bool,
    privateKey: **const bssl.c.br_rsa_private_key,
};

fn pemCallbackCertChain(state: *HttpsInitState, data: []const u8) !void
{
    const copy = try state.allocator.dupe(u8, data);
    var newChainCert = try state.chain.addOne();
    newChainCert.data = &copy[0];
    newChainCert.data_len = copy.len;
}

fn pemCallbackPrivateKey(state: *HttpsInitState, data: []const u8) !void
{
    if (state.privateKeySet) {
        return error.MultiplePrivateKeys;
    }

    bssl.c.br_skey_decoder_init(state.skeyContext);
    bssl.c.br_skey_decoder_push(state.skeyContext, &data[0], data.len);
    const decoderErr = bssl.c.br_skey_decoder_last_error(state.skeyContext);
    if (decoderErr != 0) {
        return error.br_skey_decoder_error;
    }
    const keyType = bssl.c.br_skey_decoder_key_type(state.skeyContext);
    if (keyType != bssl.c.BR_KEYTYPE_RSA) {
        return error.nonRsaKeyType;
    }
    state.privateKey.* = bssl.c.br_skey_decoder_get_rsa(state.skeyContext) orelse {
        return error.getRsaFailed;
    };
    state.privateKeySet = true;
}
