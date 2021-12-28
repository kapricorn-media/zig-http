const std = @import("std");

pub const MAX_HEADERS = 8 * 1024;

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
    var i: @TypeOf(reqOrRes.numHeaders) = 0;
    while (i < reqOrRes.numHeaders) : (i += 1) {
        if (std.mem.eql(u8, reqOrRes.headers[i].name, header)) {
            return reqOrRes.headers[i].value;
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

pub fn readHeaders(reqOrRes: anytype, headerIt: *std.mem.SplitIterator(u8)) !void
{
    reqOrRes.numHeaders = 0;
    while (true) {
        const header = headerIt.next() orelse {
            return error.UnexpectedEndOfHeader;
        };
        if (header.len == 0) {
            break;
        }

        var itHeader = std.mem.split(u8, header, ":");
        reqOrRes.headers[reqOrRes.numHeaders].name = itHeader.next() orelse {
            return error.HeaderMissingName;
        };
        const v = itHeader.rest();
        reqOrRes.headers[reqOrRes.numHeaders].value = std.mem.trimLeft(u8, v, " ");
        reqOrRes.numHeaders += 1;
    }
}
