const std = @import("std");
const t = std.testing;

const client = @import("http-client");
const http = @import("http-common");

test "HTTP GET www.google.com"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer t.expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});
    var allocator = gpa.allocator();

    var data: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    // TODO implement more than 1 chunk
    try t.expectError(
        error.ResponseError,
        client.httpGet("www.google.com", "/", null, allocator, &data, &response)
    );
    // defer data.deinit();
    // try t.expectEqual(http.Code._200, response.code);
    // try t.expectEqualSlices(u8, "OK", response.message);
    // try t.expect(response.body.len > 0);
}

test "HTTPS GET www.google.com"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer t.expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});
    var allocator = gpa.allocator();

    var data: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    // TODO implement
    try t.expectError(
        error.ResponseError,
        client.httpsGet("www.google.com", "/", null, allocator, &data, &response)
    );
    // defer data.deinit();
    // try t.expectEqual(http.Code._200, response.code);
    // try t.expectEqualSlices(u8, "OK", response.message);
    // try t.expect(response.body.len > 0);
}
