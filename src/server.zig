const builtin = @import("builtin");
const std = @import("std");

const bssl = @import("bearssl");
const http = @import("http-common");
const net_io = http.net_io;

const POLL_EVENTS = if (builtin.os.tag == .windows) std.os.POLL.ERR | std.os.POLL.HUP | std.os.POLL.NVAL | std.os.POLL.WRNORM | std.os.POLL.WRBAND | std.os.POLL.RDNORM | std.os.POLL.RDBAND
    else std.os.POLL.IN | std.os.POLL.PRI | std.os.POLL.OUT | std.os.POLL.ERR | std.os.POLL.HUP | std.os.POLL.NVAL;

pub const Writer = net_io.Stream.Writer;

pub const Request = struct {
    method: http.Method,
    /// full URI, including query params
    uriFull: []const u8,
    /// just the path, no query params
    uri: []const u8,
    queryParamsBuf: [http.MAX_QUERY_PARAMS]http.QueryParam,
    queryParams: []http.QueryParam,
    version: http.Version,
    headers: []http.Header,
    body: []const u8,

    const Self = @This();

    /// For string formatting, easy printing/debugging.
    pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void
    {
        _ = fmt; _ = options;
        try std.fmt.format(
            writer,
            "[method={} uri={s} version={} headers.len={} body.len={}]",
            .{self.method, self.uri, self.version, self.headers.len, self.body.len}
        );
    }

    fn loadHeaderData(self: *Self, header: []const u8, allocator: std.mem.Allocator) !void
    {
        var it = std.mem.split(u8, header, "\r\n");

        const first = it.next() orelse return error.NoFirstLine;
        var itFirst = std.mem.split(u8, first, " ");
        const methodString = itFirst.next() orelse return error.NoHttpMethod;
        self.method = http.stringToMethod(methodString) orelse return error.UnknownHttpMethod;
        const uriEncoded = itFirst.next() orelse return error.NoUri;
        self.uriFull = try http.uriDecode(uriEncoded, allocator);
        errdefer allocator.free(self.uriFull);
        try http.readQueryParams(self, self.uriFull);
        const versionString = itFirst.rest();
        self.version = http.stringToVersion(versionString) orelse return error.UnknownHttpVersion;

        try http.readHeaders(self, &it, allocator);

        const rest = it.rest();
        if (rest.len != 0) {
            return error.TrailingStuff;
        }
    }

    fn unloadHeaderData(self: *Self, allocator: std.mem.Allocator) void
    {
        if (self.headers.len > 0) {
            for (self.headers) |h| {
                if (h.name.len > 0) {
                    allocator.free(h.name);
                }
                if (h.value.len > 0) {
                    allocator.free(h.value);
                }
            }
            allocator.free(self.headers);
        }
    }

    fn deinit(self: *Self, allocator: std.mem.Allocator) void
    {
        allocator.free(self.uriFull);
    }
};

const ConnectionHttps = struct {
    context: bssl.c.br_ssl_server_context,
    buf: []u8,
};

pub const HttpsOptions = struct {
    certChainFileData: []const u8,
    privateKeyFileData: []const u8,
};

const HttpsState = struct {
    chain: bssl.crt.Chain,
    key: bssl.key.PrivateKey,
};

pub fn Server(comptime UserDataType: type) type
{
    const CBType = *const fn(
        userData: UserDataType,
        request: Request,
        writer: Writer
    ) anyerror!void;

    const Connection = struct {
        active: std.atomic.Atomic(bool),
        callback: CBType,
        userData: UserDataType,
        https: ?ConnectionHttps,
        stream: net_io.Stream,
        address: std.net.Address,
        thread: std.Thread,

        const Self = @This();

        fn init(
            callback: CBType,
            userData: UserDataType,
            https: bool,
            allocator: std.mem.Allocator) !Self
        {
            if (builtin.os.tag != .windows) {
                // Ignore SIGPIPE
                var act = std.os.Sigaction{
                    .handler = .{ .handler = std.os.SIG.IGN },
                    .mask = std.os.empty_sigset,
                    .flags = 0,
                };
                try std.os.sigaction(std.os.SIG.PIPE, &act, null);
            }

            var self = Self {
                .active = std.atomic.Atomic(bool).init(false),
                .callback = callback,
                .userData = userData,
                .https = null,
                .stream = undefined,
                .address = undefined,
                .thread = undefined,
            };
            if (https) {
                self.https = ConnectionHttps {
                    .context = undefined,
                    .buf = try allocator.alloc(u8, bssl.c.BR_SSL_BUFSIZE_BIDI),
                };
            }
            return self;
        }

        fn deinit(self: Self, allocator: std.mem.Allocator) void
        {
            if (self.https) |h| {
                allocator.free(h.buf);
            }
        }

        fn load(
            self: *Self,
            sockfd: std.os.socket_t,
            address: std.net.Address,
            https: ?HttpsState,
            allocator: std.mem.Allocator) !void
        {
            std.debug.assert((self.https == null and https == null) or (self.https != null and https != null));
            var engine: ?*bssl.c.br_ssl_engine_context = null;
            if (self.https) |_| {
                bssl.c.br_ssl_server_init_full_rsa(
                    &self.https.?.context,
                    &https.?.chain.chain[0], https.?.chain.chain.len,
                    &https.?.key.rsaKey);
                bssl.c.br_ssl_engine_set_buffer(
                    &self.https.?.context.eng,
                    &self.https.?.buf[0], self.https.?.buf.len, 1);
                if (bssl.c.br_ssl_server_reset(&self.https.?.context) != 1) {
                    return error.br_ssl_server_reset;
                }

                engine = &self.https.?.context.eng;
            }

            self.active.store(true, .Release);
            errdefer self.active.store(false, .Release);
            self.stream = net_io.Stream.init(sockfd, engine);
            self.address = address;
            self.thread = try std.Thread.spawn(.{}, handleRequestWrapper, .{self, allocator});
            self.thread.detach();
        }

        fn handleRequestWrapper(self: *Self, allocator: std.mem.Allocator) void
        {
            self.handleRequest(allocator) catch |err| {
                std.log.warn("handleRequest error {}", .{err});
            };
        }

        fn handleRequest(self: *Self, allocator: std.mem.Allocator) !void
        {
            var buf: [4098]u8 = undefined;

            defer {
                self.active.store(false, .Release);
                std.os.closeSocket(self.stream.sockfd);
            }

            var request = Request {
                .method = undefined,
                .uriFull = undefined,
                .uri = undefined,
                .queryParamsBuf = undefined,
                .queryParams = undefined,
                .version = undefined,
                .headers = &.{},
                .body = &.{},
            };
            defer request.unloadHeaderData(allocator);
            var requestLoaded = false;
            defer {
                if (requestLoaded) {
                    request.deinit(allocator);
                }
            }
            var parsedHeader = false;
            var header = std.ArrayList(u8).init(allocator);
            defer header.deinit();
            var body = std.ArrayList(u8).init(allocator);
            defer body.deinit();
            var contentLength: usize = 0;
            while (true) {
                const timeout = 500; // milliseconds, TODO make configurable
                const pollResult = try self.stream.pollIn(timeout);
                if (pollResult == 0) {
                    continue;
                }

                const n = self.stream.read(&buf) catch |err| switch (err) {
                    error.WouldBlock => {
                        continue;
                    },
                    else => {
                        return err;
                    },
                };
                if (n == 0) {
                    break;
                }

                const bytes = buf[0..n];
                if (!parsedHeader) {
                    try header.appendSlice(bytes);
                    if (std.mem.indexOf(u8, header.items, "\r\n\r\n")) |ind| {
                        const headerLength = ind + 4;
                        try request.loadHeaderData(header.items[0..headerLength], allocator);
                        requestLoaded = true;
                        contentLength = http.getContentLength(request) catch |err| blk: {
                            switch (err) {
                                error.NoContentLength => {},
                                error.InvalidContentLength => {
                                    std.log.warn("Content-Length invalid, assuming 0", .{});
                                },
                            }
                            break :blk 0;
                        };

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

            self.callback(self.userData, request, self.stream.writer()) catch |err| {
                return err;
            };

            try self.stream.flush();
        }
    };

    const ServerType = struct {
        allocator: std.mem.Allocator,
        callback: CBType,
        userData: UserDataType,
        listening: std.atomic.Atomic(bool),
        listenExited: std.atomic.Atomic(bool),
        sockfd: std.os.socket_t,
        listenAddress: std.net.Address,
        connections: []Connection,
        httpsState: ?HttpsState,

        const Self = @This();

        /// Server request callback type.
        /// Don't return errors for plain application-specific stuff you can handle thru HTTP codes.
        /// Errors should be used only for IO failures, tests, or other very special situations.
        pub const CallbackType = CBType;

        pub fn init(
            callback: CBType,
            userData: UserDataType,
            httpsOptions: ?HttpsOptions,
            allocator: std.mem.Allocator) !Self
        {
            var self = Self {
                .allocator = allocator,
                .callback = callback,
                .userData = userData,
                .listening = std.atomic.Atomic(bool).init(false),
                .listenExited = std.atomic.Atomic(bool).init(true),
                .sockfd = undefined,
                .listenAddress = undefined,
                .connections = try allocator.alloc(Connection, 1024),
                .httpsState = null,
            };
            errdefer allocator.free(self.connections);

            if (httpsOptions) |options| {
                self.httpsState = HttpsState {
                    .chain = try bssl.crt.Chain.init(options.certChainFileData, allocator),
                    .key = try bssl.key.PrivateKey.initFromPem(options.privateKeyFileData, allocator),
                };
            }

            for (self.connections) |_, i| {
                self.connections[i] = try Connection.init(callback, userData, self.httpsState != null, allocator);
            }

            return self;
        }

        pub fn deinit(self: *Self) void
        {
            if (self.listening.load(.Acquire)) {
                std.log.err("server deinit called without stop", .{});
            }

            for (self.connections) |_, i| {
                self.connections[i].deinit(self.allocator);
            }
            self.allocator.free(self.connections);

            if (self.httpsState) |_| {
                self.httpsState.?.chain.deinit(self.allocator);
                self.httpsState.?.key.deinit(self.allocator);
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
            defer std.os.closeSocket(self.sockfd);
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

                var pollFds = [_]std.os.pollfd {
                    .{
                        .fd = self.sockfd,
                        .events = POLL_EVENTS,
                        .revents = undefined,
                    },
                };
                const timeout = 100; // milliseconds, TODO make configurable
                const pollResult = try std.os.poll(&pollFds, timeout);
                if (pollResult == 0) {
                    continue;
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
                        std.os.AcceptError.WouldBlock => {},
                        else => {
                            std.log.err("accept error {}", .{err});
                        },
                    }
                    continue;
                };
                errdefer std.os.closeSocket(fd);

                var slot: ?usize = null;
                while (slot == null) {
                    slot = self.findConnectionSlot();
                    std.log.debug("Waiting for connection slot", .{});
                }

                // TODO use cheaper allocator
                self.connections[slot.?].load(fd, acceptedAddress, self.httpsState, self.allocator) catch |err| {
                    std.log.err("connection load error {}", .{err});
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

        fn findConnectionSlot(self: *Self) ?usize
        {
            for (self.connections) |_, i| {
                if (!self.connections[i].active.load(.Acquire)) {
                    return i;
                }
            }
            return null;
        }
    };

    return ServerType;
}

pub fn writeCode(writer: Writer, code: http.Code) !void
{
    const versionString = http.versionToString(http.Version.v1_1);
    try std.fmt.format(
        writer,
        "{s} {} {s}\r\n",
        .{versionString, @enumToInt(code), http.getCodeMessage(code)}
    );
}

pub fn writeHeader(writer: Writer, header: http.Header) !void
{
    try std.fmt.format(writer, "{s}: {s}\r\n", .{header.name, header.value});
}

pub fn writeContentLength(writer: Writer, contentLength: usize) !void
{
    try std.fmt.format(writer, "Content-Length: {}\r\n", .{contentLength});
}

pub fn writeContentType(writer: Writer, contentType: http.ContentType) !void
{
    const string = http.contentTypeToString(contentType);
    try writeHeader(writer, .{.name = "Content-Type", .value = string});
}

pub fn writeEndHeader(writer: Writer) !void
{
    try writer.writeAll("\r\n");
}

// TODO move to common.zig ?
pub fn getFileContentType(path: []const u8) ?http.ContentType
{
    const Mapping = struct {
        extension: []const u8,
        contentType: http.ContentType,
    };

    const mappings = [_]Mapping {
        // Pulled from civetweb.c. Thanks!
        // IANA registered MIME types (http://www.iana.org/assignments/media-types)
        // application types
        .{.extension = ".doc", .contentType = .ApplicationMsword},
        .{.extension = ".eps", .contentType = .ApplicationPostscript},
        .{.extension = ".exe", .contentType = .ApplicationOctetStream},
        .{.extension = ".js", .contentType = .ApplicationJavascript},
        .{.extension = ".json", .contentType = .ApplicationJson},
        .{.extension = ".pdf", .contentType = .ApplicationPdf},
        .{.extension = ".ps", .contentType = .ApplicationPostscript},
        .{.extension = ".rtf", .contentType = .ApplicationRtf},
        .{.extension = ".xhtml", .contentType = .ApplicationXhtmlXml},
        .{.extension = ".xsl", .contentType = .ApplicationXml},
        .{.extension = ".xslt", .contentType = .ApplicationXml},
        // fonts
        .{.extension = ".ttf", .contentType = .ApplicationFontSfnt},
        .{.extension = ".cff", .contentType = .ApplicationFontSfnt},
        .{.extension = ".otf", .contentType = .ApplicationFontSfnt},
        .{.extension = ".aat", .contentType = .ApplicationFontSfnt},
        .{.extension = ".sil", .contentType = .ApplicationFontSfnt},
        .{.extension = ".pfr", .contentType = .ApplicationFontTdpfr},
        .{.extension = ".woff", .contentType = .ApplicationFontWoff},
        // audio
        .{.extension = ".mp3", .contentType = .AudioMpeg},
        .{.extension = ".oga", .contentType = .AudioOgg},
        .{.extension = ".ogg", .contentType = .AudioOgg},
        // image
        .{.extension = ".gif", .contentType = .ImageGif},
        .{.extension = ".ief", .contentType = .ImageIef},
        .{.extension = ".jpeg", .contentType = .ImageJpeg},
        .{.extension = ".jpg", .contentType = .ImageJpeg},
        .{.extension = ".jpm", .contentType = .ImageJpm},
        .{.extension = ".jpx", .contentType = .ImageJpx},
        .{.extension = ".png", .contentType = .ImagePng},
        .{.extension = ".svg", .contentType = .ImageSvgXml},
        .{.extension = ".tif", .contentType = .ImageTiff},
        .{.extension = ".tiff", .contentType = .ImageTiff},
        // model
        .{.extension = ".wrl", .contentType = .ModelVrml},
        // text
        .{.extension = ".css", .contentType = .TextCss},
        .{.extension = ".csv", .contentType = .TextCsv},
        .{.extension = ".htm", .contentType = .TextHtml},
        .{.extension = ".html", .contentType = .TextHtml},
        .{.extension = ".sgm", .contentType = .TextSgml},
        .{.extension = ".shtm", .contentType = .TextHtml},
        .{.extension = ".shtml", .contentType = .TextHtml},
        .{.extension = ".txt", .contentType = .TextPlain},
        .{.extension = ".xml", .contentType = .TextXml},
        // video
        .{.extension = ".mov", .contentType = .VideoQuicktime},
        .{.extension = ".mp4", .contentType = .VideoMp4},
        .{.extension = ".mpeg", .contentType = .VideoMpeg},
        .{.extension = ".mpg", .contentType = .VideoMpeg},
        .{.extension = ".ogv", .contentType = .VideoOgg},
        .{.extension = ".qt", .contentType = .VideoQuicktime},
        // not registered types
        // (http://reference.sitepoint.com/html/mime-types-full,
        //  http://www.hansenb.pdx.edu/DMKB/dict/tutorials/mime_typ.php, ...)
        .{.extension = ".arj", .contentType = .ApplicationXArjCompressed},
        .{.extension = ".gz", .contentType = .ApplicationXGunzip},
        .{.extension = ".rar", .contentType = .ApplicationXArjCompressed},
        .{.extension = ".swf", .contentType = .ApplicationXShockwaveFlash},
        .{.extension = ".tar", .contentType = .ApplicationXTar},
        .{.extension = ".tgz", .contentType = .ApplicationXTarGz},
        .{.extension = ".torrent", .contentType = .ApplicationXBittorrent},
        .{.extension = ".ppt", .contentType = .ApplicationXMspowerpoint},
        .{.extension = ".xls", .contentType = .ApplicationXMsexcel},
        .{.extension = ".zip", .contentType = .ApplicationXZipCompressed},
        .{.extension = ".aac", .contentType = .AudioAac}, // http://en.wikipedia.org/wiki/Advanced_Audio_Coding
        .{.extension = ".aif", .contentType = .AudioXAif},
        .{.extension = ".m3u", .contentType = .AudioXMpegurl},
        .{.extension = ".mid", .contentType = .AudioXMidi},
        .{.extension = ".ra", .contentType = .AudioXPnRealaudio},
        .{.extension = ".ram", .contentType = .AudioXPnRealaudio},
        .{.extension = ".wav", .contentType = .AudioXWav},
        .{.extension = ".bmp", .contentType = .ImageBmp},
        .{.extension = ".ico", .contentType = .ImageXIcon},
        .{.extension = ".pct", .contentType = .ImageXPct},
        .{.extension = ".pict", .contentType = .ImagePict},
        .{.extension = ".rgb", .contentType = .ImageXRgb},
        .{.extension = ".webm", .contentType = .VideoWebm}, // http://en.wikipedia.org/wiki/WebM
        .{.extension = ".asf", .contentType = .VideoXMsAsf},
        .{.extension = ".avi", .contentType = .VideoXMsvideo},
        .{.extension = ".m4v", .contentType = .VideoXM4v},
        // newer (added by me)
        .{.extension = ".wasm", .contentType = .ApplicationWasm},
    };

    const extension = std.fs.path.extension(path);
    for (mappings) |m| {
        if (std.mem.eql(u8, extension, m.extension)) {
            return m.contentType;
        }
    }
    return null;
}

pub fn writeFileResponse(
    writer: Writer,
    relativePath: []const u8,
    allocator: std.mem.Allocator) !void
{
    const cwd = std.fs.cwd();
    const file = cwd.openFile(relativePath, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try writeCode(writer, ._404);
            try writeContentLength(writer, 0);
            try writeEndHeader(writer);
            return;
        },
        else => return err,
    };
    defer file.close();
    const fileData = try file.readToEndAlloc(allocator, 1024 * 1024 * 1024);
    defer allocator.free(fileData);

    try writeCode(writer, ._200);
    try writeContentLength(writer, fileData.len);
    if (getFileContentType(relativePath)) |contentType| {
        try writeContentType(writer, contentType);
    }
    try writeEndHeader(writer);
    try writer.writeAll(fileData);
}

fn uriHasFileExtension(uri: []const u8) bool
{
    var dotAfterSlash = false;
    for (uri) |c| {
        if (c == '.') {
            dotAfterSlash = true;
        }
        else if (c == '/') {
            dotAfterSlash = false;
        }
    }
    return dotAfterSlash;
}

pub fn writeRedirectResponse(writer: Writer, redirectUrl: []const u8) !void
{
    try writeCode(writer, ._301);
    try writeHeader(writer, .{.name = "Location", .value = redirectUrl});
    try writeEndHeader(writer);
}

pub fn serveStatic(
    writer: Writer,
    uri: []const u8,
    comptime dir: []const u8,
    allocator: std.mem.Allocator) !void
{
    if (uri.len == 0) {
        return error.emptyUri;
    }
    if (uri.len > 1 and uri[1] == '/') {
        return error.absolutePathInUri;
    }

    var prevWasDot = false;
    for (uri) |c| {
        if (c == '.') {
            if (prevWasDot) {
                return error.doubleDotInUri;
            }
            prevWasDot = true;
        } else {
            prevWasDot = false;
        }
    }

    const suffix = blk: {
        if (uri[uri.len - 1] == '/') {
            break :blk "index.html";
        } else if (!uriHasFileExtension(uri)) {
            break :blk "/index.html";
        } else {
            break :blk "";
        }
    };

    const path = try std.fmt.allocPrint(
        allocator,
        dir ++ "/{s}{s}",
        .{uri[1..], suffix}
    );
    defer allocator.free(path);
    try writeFileResponse(writer, path, allocator);
}
