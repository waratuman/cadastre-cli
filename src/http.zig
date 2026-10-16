//! One HTTP exchange with std.http.Client: the whole body read into memory
//! (answers are small JSON), the headers the CLI acts on kept, and network
//! failures turned into a message that names the host.
const std = @import("std");
const App = @import("App.zig");
const build_options = @import("build_options");

pub const user_agent = "cadastre-cli/" ++ build_options.version;

pub const Response = struct {
    status: u16,
    body: []const u8,
    retry_after: ?[]const u8 = null,
    www_authenticate: ?[]const u8 = null,
    content_type: ?[]const u8 = null,

    pub fn ok(r: Response) bool {
        return r.status >= 200 and r.status < 300;
    }
};

pub const Request = struct {
    method: std.http.Method = .GET,
    url: []const u8,
    /// `Authorization: Bearer <token>`.
    bearer: ?[]const u8 = null,
    body: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
};

const max_body = 32 << 20;

/// Sends the request. A network failure is reported (exit 1) here.
pub fn send(app: *App, req: Request) App.Error!Response {
    return sendInner(app, req) catch |err| switch (err) {
        error.InvalidUrl => app.fail(.usage, "not a valid URL: {s}", .{req.url}),
        error.OutOfMemory => app.fail(.failure, "out of memory", .{}),
        else => app.fail(.failure, "could not reach {s}: {s}{s}", .{ hostOf(req.url), describe(err), hint(err) }),
    };
}

fn hostOf(url: []const u8) []const u8 {
    const start = if (std.mem.indexOf(u8, url, "://")) |i| i + 3 else 0;
    const rest = url[start..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return rest[0..end];
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.ConnectionRefused => "connection refused",
        error.UnknownHostName, error.NameServerFailure, error.HostLacksNetworkAddresses => "the host name did not resolve",
        error.NetworkUnreachable, error.NetworkDown => "the network is unreachable",
        error.ConnectionTimedOut, error.Timeout => "the connection timed out",
        error.ConnectionResetByPeer, error.BrokenPipe, error.EndOfStream => "the connection was closed",
        error.TlsInitializationFailed, error.TlsFailure, error.TlsAlert => "the TLS handshake failed",
        error.CertificateBundleLoadFailure => "the system's CA certificates could not be loaded",
        error.StreamTooLong => "the answer was too large",
        else => @errorName(err),
    };
}

fn hint(err: anyerror) []const u8 {
    return switch (err) {
        error.ConnectionRefused => " (is the server running? check --base-url / CADASTRE_BASE_URL)",
        error.UnknownHostName, error.NameServerFailure, error.HostLacksNetworkAddresses, error.NetworkUnreachable, error.NetworkDown => " (are you online?)",
        else => "",
    };
}

fn sendInner(app: *App, r: Request) !Response {
    const gpa = app.gpa;
    const uri = std.Uri.parse(r.url) catch return error.InvalidUrl;
    const c = app.client();

    var auth_value: ?[]const u8 = null;
    if (r.bearer) |token| auth_value = try std.fmt.allocPrint(gpa, "Bearer {s}", .{token});

    var req = try c.request(r.method, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = true,
        .headers = .{
            .user_agent = .{ .override = user_agent },
            .authorization = if (auth_value) |v| .{ .override = v } else .omit,
            .content_type = if (r.content_type) |ct| .{ .override = ct } else .default,
        },
        .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
    });
    defer req.deinit();

    if (r.body) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(payload);
        try body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var response = try req.receiveHead(&.{});
    var out: Response = .{ .status = @intFromEnum(response.head.status), .body = "" };
    // The head's memory is reused once the body is read: copy what we keep.
    var it = response.head.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) {
            out.retry_after = try gpa.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "www-authenticate")) {
            out.www_authenticate = try gpa.dupe(u8, h.value);
        } else if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
            out.content_type = try gpa.dupe(u8, h.value);
        }
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    out.body = reader.allocRemaining(gpa, .limited(max_body)) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };
    return out;
}

const testing = std.testing;

test "hostOf names the host of a URL" {
    try testing.expectEqualStrings("getcadastre.com", hostOf("https://getcadastre.com/api/v1/me"));
    try testing.expectEqualStrings("127.0.0.1:3000", hostOf("http://127.0.0.1:3000"));
}

test "the user agent carries the version" {
    try testing.expect(std.mem.startsWith(u8, user_agent, "cadastre-cli/"));
    try testing.expect(user_agent.len > "cadastre-cli/".len);
}
