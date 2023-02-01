const std = @import("std");
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

const http = @import("http-common");

const Params = struct {
    requestPath: []const u8,
    err: ?http.QueryParamError,
    expectedUri: ?[]const u8,
    expectedParams: ?[]const http.QueryParam,
};

fn testQueryParams(params: Params) !void
{
    const DummyRequest = struct {
        uri: []const u8,
        queryParamsBuf: [http.MAX_QUERY_PARAMS]http.QueryParam,
        queryParams: []http.QueryParam,
    };
    var request = DummyRequest {
        .uri = undefined,
        .queryParamsBuf = undefined,
        .queryParams = undefined,
    };

    const result = http.readQueryParams(&request, params.requestPath);
    if (params.err) |err| {
        try expect(params.expectedUri == null);
        try expect(params.expectedParams == null);

        try expectError(err, result);
    } else {
        const expectedUri = params.expectedUri orelse return error.NeedExpectedUri;
        const expectedParams = params.expectedParams orelse return error.NeedExpectedParams;

        try result;
        try expectEqualSlices(u8, expectedUri, request.uri);
        try expectEqual(expectedParams.len, request.queryParams.len);
        for (expectedParams) |_, i| {
            try expectEqualSlices(u8, expectedParams[i].name, request.queryParams[i].name);
            try expectEqualSlices(u8, expectedParams[i].value, request.queryParams[i].value);
        }
    }
}

fn testQueryParamsSuccess(
    requestPath: []const u8,
    expectedUri: []const u8,
    expectedParams: []const http.QueryParam) !void
{
    try testQueryParams(.{
        .requestPath = requestPath,
        .err = null,
        .expectedUri = expectedUri,
        .expectedParams = expectedParams,
    });
}

fn testQueryParamsFail(
    requestPath: []const u8,
    err: http.QueryParamError) !void
{
    try testQueryParams(.{
        .requestPath = requestPath,
        .err = err,
        .expectedUri = null,
        .expectedParams = null,
    });
}

test "query params"
{
    const emptyParams = [0]http.QueryParam{};
    try testQueryParamsSuccess("/", "/", &emptyParams);
    try testQueryParamsSuccess("/testing", "/testing", &emptyParams);
    try testQueryParamsSuccess("/something&very=weird", "/something&very=weird", &emptyParams);
    try testQueryParamsSuccess("/testing?param1=value1", "/testing", &.{
        .{.name = "param1", .value = "value1"},
    });
    try testQueryParamsSuccess("/testing?param1=value1&param2=value2&param3=value3&param4=value4",
        "/testing",
        &.{
            .{.name = "param1", .value = "value1"},
            .{.name = "param2", .value = "value2"},
            .{.name = "param3", .value = "value3"},
            .{.name = "param4", .value = "value4"},
        }
    );
    try testQueryParamsSuccess("?there=is&no=uri", "", &.{
        .{.name = "there", .value = "is"},
        .{.name = "no", .value = "uri"},
    });
    try testQueryParamsSuccess("/a/very/complicated/uri/?with=a&trailing=slash&param123=value321",
        "/a/very/complicated/uri/",
        &.{
            .{.name = "with", .value = "a"},
            .{.name = "trailing", .value = "slash"},
            .{.name = "param123", .value = "value321"},
        }
    );
    try testQueryParamsSuccess("/a/very/complicated/uri/?=missing&=names!!&param123=value321",
        "/a/very/complicated/uri/",
        &.{
            .{.name = "", .value = "missing"},
            .{.name = "", .value = "names!!"},
            .{.name = "param123", .value = "value321"},
        }
    );
    try testQueryParamsSuccess("/a/very/complicated/uri/?missing!!=&values234=",
        "/a/very/complicated/uri/",
        &.{
            .{.name = "missing!!", .value = ""},
            .{.name = "values234", .value = ""},
        }
    );

    try testQueryParamsFail("/too?many?questionmarks", error.ExtraQuestionMarks);
    try testQueryParamsFail("/incomplete/param/?", error.IncompleteParam);
    try testQueryParamsFail("/incomplete/param/?name", error.IncompleteParam);
    try testQueryParamsFail("/incomplete/param/?name1&name2", error.IncompleteParam);
    try testQueryParamsFail("/incomplete/param/?name1=value1&name2", error.IncompleteParam);
    try testQueryParamsFail("/incomplete/param/?name1=value1&&name2=value2", error.IncompleteParam);
    try testQueryParamsFail("/too/many/equals?name1==value1", error.ExtraEquals);
    try testQueryParamsFail("/too/many/equals?name1==value1&name2=value2", error.ExtraEquals);
    try testQueryParamsFail("/too/many/equals?name1=value1&name2==value2", error.ExtraEquals);
    try testQueryParamsFail("/too/many/equals?name1=value1&name2=value2=", error.ExtraEquals);
    try testQueryParamsFail("/too/many/equals?name1=value1&name2=value2=value3", error.ExtraEquals);
}

fn testUriEncodingSuccess(encoded: []const u8, decoded: []const u8) !void
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer expect(!gpa.deinit()) catch |err| std.log.err("{}", .{err});
    var allocator = gpa.allocator();

    const decodedActual = try http.uriDecode(encoded, allocator);
    defer allocator.free(decodedActual);
    try expectEqualSlices(u8, decoded, decodedActual);

    // TODO
    // const encodedActual = try http.uriEncode(decoded, allocator);
    // defer allocator.free(encodedActual);
    // try expectEqualSlices(u8, encoded, encodedActual);
}

fn testUriDecodeFail(encoded: []const u8, err: http.UriDecodeError) !void
{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) std.log.err("leaks!", .{});
    var allocator = gpa.allocator();

    try expectError(err, http.uriDecode(encoded, allocator));
}

test "URI encoding/decoding"
{
    try testUriEncodingSuccess("", "");
    try testUriEncodingSuccess("/normal_stuff", "/normal_stuff");
    try testUriEncodingSuccess("/hello?name=value", "/hello?name=value");
    try testUriEncodingSuccess("/hello?name=the value", "/hello?name=the value");
    try testUriEncodingSuccess("/hello?name=the%20value", "/hello?name=the value");
    try testUriEncodingSuccess("%23", "#");
    try testUriEncodingSuccess("ABC%20abc%20123", "ABC abc 123");
    try testUriEncodingSuccess("%D1%88%D0%B5%D0%BB%D0%BB%D1%8B", "шеллы");
    try testUriEncodingSuccess("%3B%2C%2F%3F%3A%40%26%3D%2B%24", ";,/?:@&=+$");
    try testUriEncodingSuccess(
        "%00%01%02%03%04%05%06%07%08%09%0a%0B%0c%0D%0e%0F%10",
        "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10");
    try testUriEncodingSuccess("-_.!~*'()", "-_.!~*'()");

    try testUriDecodeFail("/hello%", error.BadPercentSequence);
    try testUriDecodeFail("/incomplete/%A", error.BadPercentSequence);
    try testUriDecodeFail("/incomplete/%a", error.BadPercentSequence);
    try testUriDecodeFail("/incomplete/%i", error.BadPercentSequence);
    try testUriDecodeFail("/badchars/%2i", error.BadPercentSequence);
    try testUriDecodeFail("/badchars/%2Ia", error.BadPercentSequence);
    try testUriDecodeFail("/worsechars %?Fwhat", error.BadPercentSequence);
    try testUriDecodeFail("/worsechars %?Fwhat", error.BadPercentSequence);
    try testUriDecodeFail("%  %", error.BadPercentSequence);
    try testUriDecodeFail("%2a%19%87%fg%09", error.BadPercentSequence);
    try testUriDecodeFail("%2a%19%87%ff%0g", error.BadPercentSequence);
    try testUriDecodeFail("%2a%19%87%f%0g", error.BadPercentSequence);
}
