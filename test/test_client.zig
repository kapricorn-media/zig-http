const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const client = @import("http-client");
const http = @import("http-common");

test "HTTP GET www.google.com"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});
    var allocator = gpa.allocator();

    var data: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    try client.httpGet("www.google.com", "/", null, allocator, &data, &response);
    defer data.deinit();
    try expectEqual(http.Code._200, response.code);
    try expectEqualSlices(u8, "OK", response.message);
    try expect(response.body.len > 0);
}

test "HTTPS GET www.google.com"
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});
    var allocator = gpa.allocator();

    var data: std.ArrayList(u8) = undefined;
    var response: client.Response = undefined;
    try client.httpsGet("www.google.com", "/", null, allocator, &data, &response);
    defer data.deinit();
    try expectEqual(http.Code._200, response.code);
    try expectEqualSlices(u8, "OK", response.message);
    try expect(response.body.len > 0);
}
