const std = @import("std");

const client = @import("http-client");

pub fn main() !void
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit()) {
            std.log.err("leaks!", .{});
        }
    }
    var allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer allocator.free(args);
    if (args.len < 5) {
        std.log.err("Expected at least 4 arguments: host uri port https [root-ca-path]", .{});
        return error.BadArgs;
    }

    const host = args[1];
    const uri = args[2];
    const port = try std.fmt.parseUnsigned(u16, args[3], 10);
    const https = blk: {
        const httpsStr = args[4];
        if (std.mem.eql(u8, httpsStr, "true")) {
            break :blk true;
        } else if (std.mem.eql(u8, httpsStr, "false")) {
            break :blk false;
        } else {
            return error.BadHttpsArgValue;
        }
    };
    if (args.len == 6) {
        const crtPath = args[5];
        const cwd = std.fs.cwd();
        const file = try cwd.openFile(crtPath, .{});
        defer file.close();
        const data = try file.readToEndAlloc(allocator, 1024 * 1024 * 1024);
        defer allocator.free(data);

        try client.overrideRootCaList(data, allocator);
        std.log.info("Registered root CAs from file {s}", .{crtPath});
    }

    var data: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    try client.get(https, port, host, uri, null, allocator, &data, &response);
    defer data.deinit();

    std.log.info("{}", .{response});
}
