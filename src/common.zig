const std = @import("std");

pub const net_io = @import("net_io.zig");

pub const MAX_HEADERS = 8 * 1024;
pub const MAX_QUERY_PARAMS = 8 * 1024;

pub const Code = enum(u32)
{
    _200 = 200,
    _301 = 301,
    _400 = 400,
    _401 = 401,
    _403 = 403,
    _404 = 404,
    _500 = 500,
};

pub fn intToCode(code: u32) ?Code
{
    return std.meta.intToEnum(Code, code) catch |err| switch (err) {
        error.InvalidEnumTag => null,
    };
}

pub fn getCodeMessage(code: Code) []const u8
{
    return switch (code) {
        ._200 => "OK",
        ._301 => "Moved Permanently",
        ._400 => "Bad Request",
        ._401 => "Unauthorized",
        ._403 => "Forbidden",
        ._404 => "Not Found",
        ._500 => "Internal Server Error",
    };
}

pub const ContentType = enum {
    ApplicationFontSfnt,
    ApplicationFontTdpfr,
    ApplicationFontWoff,
    ApplicationJavascript,
    ApplicationJson,
    ApplicationMsword,
    ApplicationOctetStream,
    ApplicationPdf,
    ApplicationPostscript,
    ApplicationRtf,
    ApplicationWasm,
    ApplicationXArjCompressed,
    ApplicationXBittorrent,
    ApplicationXGunzip,
    ApplicationXhtmlXml,
    ApplicationXml,
    ApplicationXMsexcel,
    ApplicationXMspowerpoint,
    ApplicationXShockwaveFlash,
    ApplicationXTar,
    ApplicationXTarGz,
    ApplicationXZipCompressed,
    AudioAac,
    AudioMpeg,
    AudioOgg,
    AudioXAif,
    AudioXMidi,
    AudioXMpegurl,
    AudioXPnRealaudio,
    AudioXWav,
    ImageBmp,
    ImageGif,
    ImageIef,
    ImageJpeg,
    ImageJpm,
    ImageJpx,
    ImagePict,
    ImagePng,
    ImageSvgXml,
    ImageTiff,
    ImageXIcon,
    ImageXPct,
    ImageXRgb,
    ModelVrml,
    TextCss,
    TextCsv,
    TextHtml,
    TextPlain,
    TextSgml,
    TextXml,
    VideoMp4,
    VideoMpeg,
    VideoOgg,
    VideoQuicktime,
    VideoWebm,
    VideoXM4v,
    VideoXMsAsf,
    VideoXMsvideo,
};

pub fn contentTypeToString(contentType: ContentType) []const u8
{
    return switch (contentType) {
        .ApplicationFontSfnt => "application/font-sfnt",
        .ApplicationFontTdpfr => "application/font-tdpfr",
        .ApplicationFontWoff => "application/font-woff",
        .ApplicationJavascript => "application/javascript",
        .ApplicationJson => "application/json",
        .ApplicationMsword => "application/msword",
        .ApplicationOctetStream => "application/octet-stream",
        .ApplicationPdf => "application/pdf",
        .ApplicationPostscript => "application/postscript",
        .ApplicationRtf => "application/rtf",
        .ApplicationWasm => "application/wasm",
        .ApplicationXArjCompressed => "application/x-arj-compressed",
        .ApplicationXBittorrent => "application/x-bittorrent",
        .ApplicationXGunzip => "application/x-gunzip",
        .ApplicationXhtmlXml => "application/xhtml+xml",
        .ApplicationXml => "application/xml",
        .ApplicationXMsexcel => "application/x-msexcel",
        .ApplicationXMspowerpoint => "application/x-mspowerpoint",
        .ApplicationXShockwaveFlash => "application/x-shockwave-flash",
        .ApplicationXTar => "application/x-tar",
        .ApplicationXTarGz => "application/x-tar-gz",
        .ApplicationXZipCompressed => "application/x-zip-compressed",
        .AudioAac => "audio/aac",
        .AudioMpeg => "audio/mpeg",
        .AudioOgg => "audio/ogg",
        .AudioXAif => "audio/x-aif",
        .AudioXMidi => "audio/x-midi",
        .AudioXMpegurl => "audio/x-mpegurl",
        .AudioXPnRealaudio => "audio/x-pn-realaudio",
        .AudioXWav => "audio/x-wav",
        .ImageBmp => "image/bmp",
        .ImageGif => "image/gif",
        .ImageIef => "image/ief",
        .ImageJpeg => "image/jpeg",
        .ImageJpm => "image/jpm",
        .ImageJpx => "image/jpx",
        .ImagePict => "image/pict",
        .ImagePng => "image/png",
        .ImageSvgXml => "image/svg+xml",
        .ImageTiff => "image/tiff",
        .ImageXIcon => "image/x-icon",
        .ImageXPct => "image/x-pct",
        .ImageXRgb => "image/x-rgb",
        .ModelVrml => "model/vrml",
        .TextCss => "text/css",
        .TextCsv => "text/csv",
        .TextHtml => "text/html",
        .TextPlain => "text/plain",
        .TextSgml => "text/sgml",
        .TextXml => "text/xml",
        .VideoMp4 => "video/mp4",
        .VideoMpeg => "video/mpeg",
        .VideoOgg => "video/ogg",
        .VideoQuicktime => "video/quicktime",
        .VideoWebm => "video/webm",
        .VideoXM4v => "video/x-m4v",
        .VideoXMsAsf => "video/x-ms-asf",
        .VideoXMsvideo => "video/x-msvideo",
    };
}

pub const Version = enum
{
    v1_0,
    v1_1,
};

pub fn versionToString(version: Version) []const u8
{
    return switch (version) {
        .v1_0 => "HTTP/1.0",
        .v1_1 => "HTTP/1.1",
    };
}

pub fn stringToVersion(string: []const u8) ?Version
{
    if (std.mem.eql(u8, string, "HTTP/1.1")) {
        return .v1_1;
    } else if (std.mem.eql(u8, string, "HTTP/1.0")) {
        return .v1_0;
    } else {
        return null;
    }
}

pub const Method = enum
{
    Get,
    Post,
};

pub fn methodToString(method: Method) []const u8
{
    return switch (method) {
        .Get => "GET",
        .Post => "POST",
    };
}

pub fn stringToMethod(str: []const u8) ?Method
{
    if (std.mem.eql(u8, str, "GET")) {
        return .Get;
    } else if (std.mem.eql(u8, str, "POST")) {
        return .Post;
    } else {
        return null;
    }
}

pub const Header = struct
{
    name: []const u8,
    value: []const u8,
};

/// Returns the value of the given header if it is present in the request/response.
/// Returns null otherwise.
pub fn getHeader(reqOrRes: anytype, header: []const u8) ?[]const u8
{
    for (reqOrRes.headers) |h| {
        if (std.mem.eql(u8, h.name, header)) {
            return h.value;
        }
    }
    return null;
}

const ContentLengthError = error {
    NoContentLength,
    InvalidContentLength,
};

pub fn getContentLength(reqOrRes: anytype) ContentLengthError!usize
{
    const string = getHeader(reqOrRes, "Content-Length") orelse return error.NoContentLength;
    return std.fmt.parseUnsigned(usize, string, 10) catch return error.InvalidContentLength;
}

pub fn readHeaders(
    reqOrRes: anytype,
    headerIt: *std.mem.SplitIterator(u8),
    allocator: std.mem.Allocator) !void
{
    var arrayList = std.ArrayList(Header).init(allocator);
    errdefer {
        for (arrayList.items) |h| {
            if (h.name.len > 0) {
                allocator.free(h.name);
            }
            if (h.value.len > 0) {
                allocator.free(h.value);
            }
        }
    }
    defer arrayList.deinit();

    while (true) {
        const header = headerIt.next() orelse {
            return error.UnexpectedEndOfHeader;
        };
        if (header.len == 0) {
            break;
        }

        var itHeader = std.mem.split(u8, header, ":");
        const newHeader = try arrayList.addOne();
        newHeader.name = &.{};
        newHeader.value = &.{};
        const name = itHeader.next() orelse {
            return error.HeaderMissingName;
        };
        if (name.len > 0) {
            newHeader.name = try allocator.dupe(u8, name);
        }
        const value = std.mem.trimLeft(u8, itHeader.rest(), " ");
        if (value.len > 0) {
            newHeader.value = try allocator.dupe(u8, value);
        }
    }
    reqOrRes.headers = arrayList.toOwnedSlice();
}

pub const QueryParamError = error {
    NoUri,
    ExtraQuestionMarks,
    IncompleteParam,
    ExtraEquals,
};

pub const QueryParam = struct {
    name: []const u8,
    value: []const u8,
};

pub fn readQueryParams(request: anytype, requestPath: []const u8) QueryParamError!void
{
    var itQMark = std.mem.split(u8, requestPath, "?");
    request.uri = itQMark.next() orelse return error.NoUri;
    const params = itQMark.next() orelse {
        request.queryParams.len = 0;
        return;
    };
    if (itQMark.next()) |_| return error.ExtraQuestionMarks;

    var itParams = std.mem.split(u8, params, "&");
    var n: usize = 0;
    while (itParams.next()) |param| {
        var itParam = std.mem.split(u8, param, "=");
        const name = itParam.next() orelse return error.IncompleteParam;
        const value = itParam.next() orelse return error.IncompleteParam;
        if (itParam.next()) |_| return error.ExtraEquals;

        request.queryParamsBuf[n].name = name;
        request.queryParamsBuf[n].value = value;
        n += 1;
    }
    request.queryParams = request.queryParamsBuf[0..n];
}

// TODO dupe in zig-bearssl tests
fn hexDigitToNumber(digit: u8) !u8
{
    if ('0' <= digit and digit <= '9') {
        return digit - '0';
    } else if ('a' <= digit and digit <= 'f') {
        return digit - 'a' + 10;
    } else if ('A' <= digit and digit <= 'F') {
        return digit - 'A' + 10;
    } else {
        return error.BadDigit;
    }
}

pub const UriDecodeError = std.mem.Allocator.Error || error {
    BadPercentSequence,
    AllocError,
};

pub fn uriDecode(uri: []const u8, allocator: std.mem.Allocator) UriDecodeError![]const u8
{
    var out = std.ArrayList(u8).initCapacity(allocator, uri.len) catch return error.AllocError;
    defer out.deinit();

    var i: usize = 0;
    while (i < uri.len) {
        if (uri[i] == '%') {
            if (i + 2 >= uri.len) {
                return error.BadPercentSequence;
            }
            const hexNum1 = hexDigitToNumber(uri[i + 1]) catch return error.BadPercentSequence;
            const hexNum2 = hexDigitToNumber(uri[i + 2]) catch return error.BadPercentSequence;
            const char = (hexNum1 << 4) + hexNum2;
            out.append(char) catch return error.AllocError;
            i += 3;
        } else {
            out.append(uri[i]) catch return error.AllocError;
            i += 1;
        }
    }

    return out.toOwnedSlice();
}

pub fn uriEncode(uri: []const u8) ![]const u8
{
    _ = uri;
    @compileError("unimplemented");
}
