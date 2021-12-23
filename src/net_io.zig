const std = @import("std");

const bssl = @import("bearssl");

fn httpsRead(userData: ?*anyopaque, data: ?[*]u8, len: usize) callconv(.C) c_int
{
    const d = data orelse return -1;
    var stream = @ptrCast(*std.net.Stream, @alignCast(@alignOf(*std.net.Stream), userData));
    const buf = d[0..len];

    const bytes = stream.read(buf) catch |err| {
        std.log.warn("httpsRead stream error {}", .{err});
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
        std.log.warn("httpsWrite stream error {}", .{err});
        return -1;
    };
    return @intCast(c_int, bytes);
}

pub const Stream = struct {
    stream: std.net.Stream,
    bsslIoContext: ?bssl.c.br_sslio_context,

    const Self = @This();

    pub const ReadError = std.net.Stream.ReadError || error {BsslReadFail};
    pub const WriteError = std.net.Stream.WriteError || error {BsslWriteFail};

    pub const Reader = std.io.Reader(*Self, ReadError, read);
    pub const Writer = std.io.Writer(*Self, WriteError, write);

    pub fn load(self: *Self, stream: std.net.Stream, engine: ?*bssl.c.br_ssl_engine_context) void
    {
        self.stream = stream;
        if (engine) |e| {
            self.bsslIoContext = std.mem.zeroes(bssl.c.br_sslio_context);
            bssl.c.br_sslio_init(
                &self.bsslIoContext.?, e,
                httpsRead, &self.stream, httpsWrite, &self.stream);
        } else {
            self.bsslIoContext = null;
        }
    }

    pub fn deinit(self: *Self) void
    {
        if (self.bsslIoContext) |_| {
            if (bssl.c.br_sslio_close(&self.bsslIoContext.?) != 0) {
                std.log.err("br_sslio_close failed", .{});
            }
        }
    }

    pub fn reader(self: *Self) Reader
    {
        return .{ .context = self };
    }

    pub fn writer(self: *Self) Writer
    {
        return .{ .context = self };
    }

    pub fn read(self: *Self, buffer: []u8) ReadError!usize
    {
        if (self.bsslIoContext) |context| {
            const result = bssl.c.br_sslio_read(&self.bsslIoContext.?, &buffer[0], buffer.len);
            if (result < 0) {
                const engState = bssl.c.br_ssl_engine_current_state(context.engine);
                const err = bssl.c.br_ssl_engine_last_error(context.engine);
                if (engState == bssl.c.BR_SSL_CLOSED and (err == bssl.c.BR_ERR_OK or err == bssl.c.BR_ERR_IO)) {
                    // TODO why BR_ERR_IO?
                    return 0;
                } else {
                    return error.BsslReadFail;
                }
            } else {
                return @intCast(usize, result);
            }
        } else {
            return try self.stream.read(buffer);
        }
    }

    pub fn write(self: *Self, buffer: []const u8) WriteError!usize
    {
        if (self.bsslIoContext) |context| {
            const result = bssl.c.br_sslio_write(&self.bsslIoContext.?, &buffer[0], buffer.len);
            if (result < 0) {
                const err = bssl.c.br_ssl_engine_last_error(context.engine);
                _ = err;
                // std.log.err("br_sslio_write fail, engine err {}", .{err});
                return error.BsslWriteFail;
            } else {
                return @intCast(usize, result);
            }
        } else {
            return try self.stream.write(buffer);
        }
    }

    pub fn flush(self: *Self) !void
    {
        if (self.bsslIoContext) |_| {
            if (bssl.c.br_sslio_flush(&self.bsslIoContext.?) != 0) {
                return error.br_sslio_flush;
            }
        }
    }
};
