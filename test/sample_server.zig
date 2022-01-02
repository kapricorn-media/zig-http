const std = @import("std");

const http = @import("http-common");
const server = @import("http-server");

const TEST_IP = "0.0.0.0";

const TEST_LOCALHOST_CRT = @embedFile("localhost.crt");
const TEST_LOCALHOST_KEY = @embedFile("localhost.key");

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
    if (args.len != 3) {
        std.log.err("Expected 2 arguments: port, https", .{});
        return error.BadArgs;
    }

    const port = try std.fmt.parseUnsigned(u16, args[1], 10);
    const https = blk: {
        const httpsStr = args[2];
        if (std.mem.eql(u8, httpsStr, "true")) {
            break :blk true;
        } else if (std.mem.eql(u8, httpsStr, "false")) {
            break :blk false;
        } else {
            return error.BadHttpsArgValue;
        }
    };

    const State = struct {
        allocator: std.mem.Allocator,
    };
    const Wrapper = struct {
        fn callback(state: *const State, request: *const server.Request, writer: server.Writer) !void
        {
            std.log.info("{}", .{request});
            try server.serveStatic(writer, request.uri, ".", state.allocator);
        }
    };

    const state = State {
        .allocator = allocator,
    };
    const httpsOptions = if (https) server.HttpsOptions {
        .certChainFileData = TEST_LOCALHOST_CRT,
        .privateKeyFileData = TEST_LOCALHOST_KEY,
    } else null;
    var s = try server.Server(*const State).init(Wrapper.callback, &state, httpsOptions, allocator);
    defer s.deinit();

    std.log.info("Listening on {s}:{} HTTPS {}", .{TEST_IP, port, https});
    s.listen(TEST_IP, port) catch |err| {
        std.log.err("server listen error {}", .{err});
    };
    defer s.stop();
}
