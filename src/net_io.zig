const std = @import("std");

const bssl = @import("bearssl");

fn httpsRead(userData: ?*anyopaque, data: ?[*]u8, len: usize) callconv(.C) c_int
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

fn httpsWrite(userData: ?*anyopaque, data: ?[*]const u8, len: usize) callconv(.C) c_int
{
    const d = data orelse return 0;
    var stream = @ptrCast(*std.net.Stream, @alignCast(@alignOf(*std.net.Stream), userData));
    const bytes = stream.write(d[0..len]) catch |err| {
        std.log.err("net stream write error {}", .{err});
        return -1;
    };
    return @intCast(c_int, bytes);
}

pub const Stream = struct {
    stream: std.net.Stream,
    bsslIoContext: ?*bssl.c.br_sslio_context,

    const Self = @This();

    pub const Reader = std.io.Reader(Self, anyerror, read);
    pub const Writer = std.io.Writer(Self, anyerror, write);

    pub fn init(stream: std.net.Stream, engine: ?*bssl.c.br_ssl_engine_context) Self
    {
        var self = Self {
            .stream = stream,
            .bsslIoContext = null,
        };
        if (engine) |e| {
            var context: *bssl.c.br_sslio_context = undefined;
            bssl.c.br_sslio_init(context, e, httpsRead, &self.stream, httpsWrite, &self.stream);
            self.bsslIoContext = context;
        }

        return self;
    }

    pub fn deinit(self: *Self) void
    {
        if (self.bsslIoContext) |context| {
            if (bssl.c.br_sslio_close(context) != 0) {
                std.log.err("br_sslio_close failed", .{});
            }
        }
    }

    pub fn reader(self: Self) Reader
    {
        return .{ .context = self };
    }

    pub fn writer(self: Self) Writer
    {
        return .{ .context = self };
    }

    pub fn read(self: Self, buffer: []u8) anyerror!usize
    {
        if (self.bsslIoContext) |context| {
            const result = bssl.c.br_sslio_read(context, &buffer[0], buffer.len);
            if (result < 0) {
                const engState = bssl.c.br_ssl_engine_current_state(context.engine);
                const err = bssl.c.br_ssl_engine_last_error(context.engine);
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

    pub fn write(self: Self, buffer: []const u8) anyerror!usize
    {
        if (self.bsslIoContext) |context| {
            const result = bssl.c.br_sslio_write(context, &buffer[0], buffer.len);
            if (result < 0) {
                const err = bssl.c.br_ssl_engine_last_error(context.engine);
                std.log.err("br_sslio_write fail, engine err {}", .{err});
                return error.bsslWriteFail;
            } else {
                return @intCast(usize, result);
            }
        } else {
            return try self.stream.write(buffer);
        }
    }

    pub fn flush(self: Self) !void
    {
        if (self.bsslIoContext) |context| {
            if (bssl.c.br_sslio_flush(context) != 0) {
                return error.br_sslio_flush;
            }
        }
    }

    pub fn close(self: Self) void
    {
        self.stream.close();
    }
};
