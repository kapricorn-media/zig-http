const builtin = @import("builtin");
const std = @import("std");

const bssl = @import("bearssl.zig");

pub const RootCaList = struct {
    list: std.ArrayList(bssl.br_x509_trust_anchor),

    const Self = @This();

    pub fn load(self: *Self, allocator: std.mem.Allocator) !void
    {
        self.list = std.ArrayList(bssl.br_x509_trust_anchor).init(allocator);

        switch (builtin.target.os.tag) {
            .linux => {
                const certsPath = "/etc/ssl/certs/ca-certificates.crt";
                const file = try std.fs.openFileAbsolute(certsPath, .{});
                defer file.close();

                const fileData = try file.readToEndAlloc(allocator, 1024 * 1024 * 1024);
                defer allocator.free(fileData);

                var remaining = fileData;
                var pemDecoder: bssl.br_pem_decoder_context = undefined;
                bssl.br_pem_decoder_init(&pemDecoder);
                var pemState = PemState {
                    .success = false,
                    .x509Decoder = undefined,
                    .list = std.ArrayList(u8).init(allocator),
                };
                defer pemState.list.deinit();
                while (remaining.len > 0) {
                    const result = bssl.br_pem_decoder_push(&pemDecoder, &remaining[0], remaining.len);
                    if (result == 0) {
                        while (true) {
                            const event = bssl.br_pem_decoder_event(&pemDecoder);
                            switch (event) {
                                0 => break,
                                bssl.BR_PEM_BEGIN_OBJ => {
                                    pemState.success = true;
                                    bssl.br_x509_decoder_init(&pemState.x509Decoder, x509Callback, &pemState);
                                    pemState.list.clearRetainingCapacity();
                                    bssl.br_pem_decoder_setdest(&pemDecoder, pemCallback, &pemState);
                                },
                                bssl.BR_PEM_END_OBJ => {
                                    if (!pemState.success) {
                                        return error.pemStateError;
                                    }

                                    // TODO dupe code
                                    const rc = bssl.br_x509_decoder_last_error(&pemState.x509Decoder);
                                    if (rc != 0) {
                                        return error.x509DecoderError;
                                    }

                                    var ta = try self.list.addOne();

                                    const dnBytesCopy = try allocator.dupe(u8, pemState.list.items);
                                    ta.dn.data = &dnBytesCopy[0];
                                    ta.dn.len = dnBytesCopy.len;

                                    const pkey = bssl.br_x509_decoder_get_pkey(&pemState.x509Decoder);
                                    if (pkey == null) {
                                        return error.br_x509_decoder_get_pkey;
                                    }
                                    try copyBrPublicKey(&ta.pkey, pkey, allocator);
                                    const isCA = bssl.br_x509_decoder_isCA(&pemState.x509Decoder);
                                    ta.flags = @intCast(c_uint, isCA);
                                },
                                bssl.BR_PEM_ERROR => return error.pemDecoderError,
                                else => return error.badPemDecoderEvent,
                            }
                        }
                        continue;
                    }

                    remaining = remaining[result..];
                }
            },
            .macos => {
                const macos_certs = @cImport(@cInclude("macos_certs.h"));
                var state = State {
                    .success = true,
                    .allocator = allocator,
                    .list = &self.list,
                    .context = undefined,
                };
                errdefer state.list.deinit();
                const rc = macos_certs.getRootCaCerts(&state, certCallback);
                if (rc != 0) {
                    return error.getRootCaCerts;
                }
                if (!state.success) {
                    return error.certStateError;
                }
            },
            else => @compileError("Unsupported OS"),
        }
    }

    pub fn deinit(self: *const Self, allocator: std.mem.Allocator) void
    {
        for (self.list.items) |ta| {
            allocator.free(ta.dn.data[0..ta.dn.len]);
            freeBrPublicKey(&ta.pkey, allocator);
        }
        self.list.deinit();
    }
};

const PemState = struct {
    success: bool,
    x509Decoder: bssl.br_x509_decoder_context,
    list: std.ArrayList(u8),
};

fn x509Callback(userData: ?*anyopaque, data: ?*const anyopaque, len: usize) callconv(.C) void
{
    var state = @ptrCast(*PemState, @alignCast(@alignOf(*PemState), userData));
    const cBytes = @ptrCast([*]const u8, data);
    const bytes = cBytes[0..len];
    state.list.appendSlice(bytes) catch {
        state.success = false;
    };
}

fn pemCallback(userData: ?*anyopaque, data: ?*const anyopaque, len: usize) callconv(.C) void
{
    var state = @ptrCast(*PemState, @alignCast(@alignOf(*PemState), userData));
    bssl.br_x509_decoder_push(&state.x509Decoder, data, len);
}

const State = struct {
    success: bool,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(bssl.br_x509_trust_anchor),
    context: bssl.br_x509_decoder_context,
};

fn copyBrBytes(dst: *[*c]u8, src: [*]const u8, len: usize, allocator: std.mem.Allocator) !void
{
    const bytes = src[0..len];
    const bytesCopy = try allocator.dupe(u8, bytes);
    dst.* = &bytesCopy[0];
}

fn copyBrPublicKey(
    dst: *bssl.br_x509_pkey,
    src: *const bssl.br_x509_pkey,
    allocator: std.mem.Allocator) !void
{
    switch (src.key_type) {
        bssl.BR_KEYTYPE_RSA => {
            try copyBrBytes(&dst.key.rsa.n, src.key.rsa.n, src.key.rsa.nlen, allocator);
            dst.key.rsa.nlen = src.key.rsa.nlen;
            try copyBrBytes(&dst.key.rsa.e, src.key.rsa.e, src.key.rsa.elen, allocator);
            dst.key.rsa.elen = src.key.rsa.elen;
        },
        bssl.BR_KEYTYPE_EC => {
            dst.key.ec.curve = src.key.ec.curve;
            try copyBrBytes(&dst.key.ec.q, src.key.ec.q, src.key.ec.qlen, allocator);
            dst.key.ec.qlen = src.key.ec.qlen;
        },
        else => return error.UnknownKeyType,
    }
    dst.key_type = src.key_type;
}

fn freeBrPublicKey(key: *const bssl.br_x509_pkey, allocator: std.mem.Allocator) void
{
    switch (key.key_type) {
        bssl.BR_KEYTYPE_RSA => {
            allocator.free(key.key.rsa.n[0..key.key.rsa.nlen]);
            allocator.free(key.key.rsa.e[0..key.key.rsa.elen]);
        },
        bssl.BR_KEYTYPE_EC => {
            allocator.free(key.key.ec.q[0..key.key.ec.qlen]);
        },
        else => {},
    }
}

const DnState = struct {
    success: bool,
    list: *std.ArrayList(u8),
};

fn dnCallback(userData: ?*anyopaque, buf: ?*const anyopaque, len: usize) callconv(.C) void
{
    var state = @ptrCast(*DnState, @alignCast(@alignOf(*DnState), userData));
    const cBytes = @ptrCast([*]const u8, buf);
    const bytes = cBytes[0..len];
    state.list.appendSlice(bytes) catch {
        state.success = false;
    };
}

fn certCallback(userData: ?*anyopaque, cBytes: [*c]const u8, length: c_int) callconv(.C) void
{
    var state = @ptrCast(*State, @alignCast(@alignOf(*State), userData));

    var dnList = std.ArrayList(u8).init(state.allocator);
    defer dnList.deinit();
    var dnState: DnState = .{
        .success = true,
        .list = &dnList,
    };
    bssl.br_x509_decoder_init(&state.context, dnCallback, &dnState);

    const bytes = cBytes[0..@intCast(usize, length)];
    bssl.br_x509_decoder_push(&state.context, &bytes[0], bytes.len);

    // TODO dupe code
    const rc = bssl.br_x509_decoder_last_error(&state.context);
    if (rc != 0) {
        std.log.err("decode failed rc {}", .{rc});
        state.success = false;
        return;
    }

    if (!dnState.success) {
        std.log.err("DN state fail", .{});
        state.success = false;
        return;
    }

    var ta = state.list.addOne() catch |err| {
        std.log.err("addOne list failed {}", .{err});
        state.success = false;
        return;
    };

    const dnBytesCopy = state.allocator.dupe(u8, dnState.list.items) catch |err| {
        std.log.err("dupe DN bytes failed {}", .{err});
        state.success = false;
        return;
    };
    ta.dn.data = &dnBytesCopy[0];
    ta.dn.len = dnBytesCopy.len;

    const pkey = bssl.br_x509_decoder_get_pkey(&state.context);
    if (pkey == null) {
        std.log.err("null public key after decoding", .{});
        state.success = false;
        return;
    }
    copyBrPublicKey(&ta.pkey, pkey, state.allocator) catch |err| {
        std.log.err("copyBrPublicKey failed {}", .{err});
        state.success = false;
        return;
    };
    const isCA = bssl.br_x509_decoder_isCA(&state.context);
    ta.flags = @intCast(c_uint, isCA);
}
