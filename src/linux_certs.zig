const std = @import("std");

const CallbackType = fn(?*anyopaque, [*c]const u8, c_int) callconv(.C) void;

pub fn getRootCaCerts(userData: ?*anyopaque, callback: CallbackType) c_int
{
    _ = userData; _ = callback;
    return 0;
}
