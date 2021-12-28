const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const server = @import("http-server");

const TEST_PORT = 19191;
const TEST_HOSTNAME = "localhost";

test "server, no SSL"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});
    var allocator = gpa.allocator();

    var httpServer = try server.Server.init(TEST_PORT, null, allocator);
    defer httpServer.deinit();
}
