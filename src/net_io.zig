const std = @import("std");

const bssl = @import("bearssl");

pub const Stream = struct {
    stream: std.net.Stream,
    engine: ?*bssl.c.br_ssl_engine_context,

    const Self = @This();

    pub const Error = std.net.Stream.ReadError || std.net.Stream.WriteError || error {BsslError};

    const Mode = enum {
        Flush,
        Read,
        Write,
    };

    pub fn init(stream: std.net.Stream, engine: ?*bssl.c.br_ssl_engine_context) Self
    {
        var self = Self {
            .stream = stream,
            .engine = engine,
        };
        return self;
    }

    pub fn read(self: Self, buffer: []u8) Error!usize
    {
        if (self.engine) |_| {
            return self.io(.Read, buffer, undefined);
        } else {
            return self.stream.read(buffer);
        }
    }

    pub fn write(self: Self, buffer: []const u8) Error!usize
    {
        if (self.engine) |_| {
            return self.io(.Write, undefined, buffer);
        } else {
            return self.stream.write(buffer);
        }
    }

    pub fn writeAll(self: Self, buffer: []const u8) Error!void
    {
        var index: usize = 0;
        while (index != buffer.len) {
            index += self.write(buffer[index..]) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => |e| return e,
            };
        }
    }

    pub fn writeByte(self: Self, byte: u8) Error!void
    {
        const array = [1]u8{byte};
        return self.writeAll(&array);
    }

    pub fn writeByteNTimes(self: Self, byte: u8, n: usize) Error!void
    {
        var bytes: [256]u8 = undefined;
        std.mem.set(u8, bytes[0..], byte);

        var remaining: usize = n;
        while (remaining > 0) {
            const to_write = std.math.min(remaining, bytes.len);
            try self.writeAll(bytes[0..to_write]);
            remaining -= to_write;
        }
    }

    pub fn flush(self: Self) Error!void
    {
        if (self.engine) |_| {
            bssl.c.br_ssl_engine_flush(self.engine, 0);
            _ = try self.io(.Flush, undefined, undefined);
        }
    }

    pub fn closeHttpsIfOpen(self: Self) Error!void
    {
        if (self.engine) |_| {
            bssl.c.br_ssl_engine_close(self.engine);
            _ = try self.io(.Flush, undefined, undefined);
        }
    }

    fn io(self: Self, mode: Mode, bufRead: []u8, bufWrite: []const u8) Error!usize
    {
        std.log.warn("{}: io {}", .{std.Thread.getCurrentId(), mode});
        if (mode == .Read) {
            // std.log.warn("len {}", .{bufRead.len});
        } else if (mode == .Write) {
            // std.log.warn("buf {s}", .{bufWrite});
        }
        var appBytes: usize = 0;
        while (true) {
            // std.log.warn("looping, appBytes {}", .{appBytes});
            const state = bssl.c.br_ssl_engine_current_state(self.engine);
            switch (state) {
                bssl.c.BR_SSL_CLOSED => {
                    const err = bssl.c.br_ssl_engine_last_error(self.engine);
                    if (err != bssl.c.BR_ERR_OK) {
                        std.log.err("closed with error {}", .{err});
                        return error.BsslError;
                    }
                    break;
                },
                0 => {
                    std.log.err("uninitialized engine", .{});
                    return error.BsslError;
                },
                else => |_| {},
            }

            const sendrec = ((state & bssl.c.BR_SSL_SENDREC) != 0);
            const recvrec = ((state & bssl.c.BR_SSL_RECVREC) != 0);
            const sendapp = ((state & bssl.c.BR_SSL_SENDAPP) != 0);
            const recvapp = ((state & bssl.c.BR_SSL_RECVAPP) != 0);
            var len: usize = undefined;
            // std.log.warn("sendapp={} recvapp={} sendrec={} recvrec={}", .{sendapp, recvapp, sendrec, recvrec});

            if (mode == .Write and sendapp) {
                const bufC = bssl.c.br_ssl_engine_sendapp_buf(self.engine, &len);
                std.debug.assert(len != 0);
                const buf = bufC[0..len];
                const n = std.math.min(buf.len, bufWrite.len);
                std.mem.copy(u8, buf[0..n], bufWrite[0..n]);
                std.log.warn(">> sendapp {}, wrote {}", .{len, n});
                bssl.c.br_ssl_engine_sendapp_ack(self.engine, n);
                appBytes = n;
                break;
            }
            if (mode == .Read and recvapp) {
                const bufC = bssl.c.br_ssl_engine_recvapp_buf(self.engine, &len);
                std.debug.assert(len != 0);
                const buf = bufC[0..len];
                const n = std.math.min(buf.len, bufRead.len);
                std.mem.copy(u8, bufRead[0..n], buf[0..n]);
                std.log.warn("<< recvapp {}, read {}", .{len, n});
                bssl.c.br_ssl_engine_recvapp_ack(self.engine, n);
                appBytes = n;
                break;
            }

            var acked = false;
            if (sendrec) {
                const bufC = bssl.c.br_ssl_engine_sendrec_buf(self.engine, &len);
                const buf = bufC[0..len];
                const n = try self.stream.write(buf);
                std.log.warn("-> sendrec {}, sent {}", .{len, n});
                if (n > 0) {
                    bssl.c.br_ssl_engine_sendrec_ack(self.engine, n);
                    acked = true;
                }
            }

            if (!acked and mode == .Flush) {
                // std.log.warn("breaking flush", .{});
                break;
            }

            if (!acked and recvrec) {
                const bufC = bssl.c.br_ssl_engine_recvrec_buf(self.engine, &len);
                const buf = bufC[0..len];
                const n = try self.stream.read(buf);
                std.log.warn("<- recvrec {}, read {}", .{len, n});
                if (n > 0) {
                    bssl.c.br_ssl_engine_recvrec_ack(self.engine, n);
                    acked = true;
                }
            }

            if (!acked and mode == .Read) {
                // std.log.warn("nothing else to read", .{});
                break;
            }
        }
        std.log.warn("appBytes {}", .{appBytes});
        return appBytes;
    }
};
