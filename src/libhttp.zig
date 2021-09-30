const std = @import("std");

const cw = @import("civetweb.zig");
pub usingnamespace cw;

pub fn start(port: u16, comptime ssl: bool, sslCertPath: [:0]const u8, allocator: *std.mem.Allocator) !*cw.mg_context
{
    var callbacks: cw.mg_callbacks = undefined;
    callbacks.begin_request = null;
    callbacks.end_request = null;
    callbacks.log_message = null;
    callbacks.log_access = null;
    callbacks.init_ssl = null;
    callbacks.connection_close = null;
    callbacks.open_file = null;
    callbacks.http_error = null;
    callbacks.init_context = null;
    callbacks.init_thread = null;
    callbacks.exit_context = null;

    const portFmt = if (ssl) "{}s" else "{}";
    const portStr = try std.fmt.allocPrintZ(allocator, portFmt, .{port});
    defer allocator.free(portStr);

    var options = std.ArrayList(?*const u8).init(allocator);
    defer options.deinit();
    try options.append(&("listening_ports")[0]);
    try options.append(&portStr[0]);
    if (ssl) {
        try options.append(&("ssl_certificate")[0]);
        try options.append(&sslCertPath[0]);
    }
    try options.append(&("error_log_file")[0]);
    try options.append(&("error.log")[0]);
    try options.append(null);

    const context = cw.mg_start(&callbacks, null, @ptrCast([*c][*c]const u8, options.items));
    if (context) |c| {
        return c;
    }
    else {
        return error.mg_start;
    }
}

pub fn stop(context: *cw.mg_context) void
{
    cw.mg_stop(context);
}
