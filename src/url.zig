//! URL building: percent-encoding, query strings and form bodies, and reading
//! the query of the OAuth redirect the loopback listener receives.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A name and an optional value; a null value is left out of the query.
pub const Param = struct { name: []const u8, value: ?[]const u8 };

fn unreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// RFC 3986 percent-encoding of everything but the unreserved characters, so
/// a value is safe in a path segment, a query or a form body.
pub fn encode(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| {
        if (unreserved(c)) {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}

pub fn encodeAlloc(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    encode(&out.writer, s) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// `name=value&...`, percent-encoded, skipping null values. Also the
/// application/x-www-form-urlencoded body of the OAuth token endpoint (spaces
/// as %20, which every form decoder accepts).
pub fn query(gpa: Allocator, params: []const Param) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    var first = true;
    for (params) |p| {
        const value = p.value orelse continue;
        if (!first) out.writer.writeByte('&') catch return error.OutOfMemory;
        first = false;
        encode(&out.writer, p.name) catch return error.OutOfMemory;
        out.writer.writeByte('=') catch return error.OutOfMemory;
        encode(&out.writer, value) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

/// `base` + `path` + `?query` (when any parameter has a value). `base` may
/// end in a slash; `path` starts with one.
pub fn build(gpa: Allocator, base: []const u8, path: []const u8, params: []const Param) Allocator.Error![]u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    const q = try query(gpa, params);
    defer gpa.free(q);
    if (q.len == 0) return std.fmt.allocPrint(gpa, "{s}{s}", .{ trimmed, path });
    return std.fmt.allocPrint(gpa, "{s}{s}?{s}", .{ trimmed, path, q });
}

/// The base URL as the CLI uses it: no trailing slash, and http(s) only.
pub fn normalizeBase(raw: []const u8) error{InvalidBaseUrl}![]const u8 {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \t"), "/");
    if (!(std.mem.startsWith(u8, trimmed, "https://") or std.mem.startsWith(u8, trimmed, "http://")))
        return error.InvalidBaseUrl;
    const rest = trimmed[std.mem.indexOf(u8, trimmed, "://").? + 3 ..];
    if (rest.len == 0 or std.mem.indexOfAny(u8, rest, "?#") != null) return error.InvalidBaseUrl;
    return trimmed;
}

/// Decodes %XX and, as forms do, '+' as a space.
pub fn decodeAlloc(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out = try gpa.alloc(u8, s.len);
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) : (n += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |byte| {
                out[n] = byte;
                i += 3;
                continue;
            } else |_| {}
        }
        out[n] = if (s[i] == '+') ' ' else s[i];
        i += 1;
    }
    return gpa.realloc(out, n);
}

/// The decoded value of `name` in a query string (`a=1&b=2`), or null.
pub fn queryValue(gpa: Allocator, q: []const u8, name: []const u8) Allocator.Error!?[]u8 {
    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key = try decodeAlloc(gpa, pair[0..eq]);
        defer gpa.free(key);
        if (std.mem.eql(u8, key, name)) {
            return try decodeAlloc(gpa, if (eq < pair.len) pair[eq + 1 ..] else "");
        }
    }
    return null;
}

const testing = std.testing;

test "encode leaves only the unreserved characters" {
    const got = try encodeAlloc(testing.allocator, "us/tx/austin-12420 a+b&c=d~_.");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("us%2Ftx%2Faustin-12420%20a%2Bb%26c%3Dd~_.", got);
}

test "build joins the base, path and the non-null parameters" {
    const got = try build(testing.allocator, "https://getcadastre.com/", "/api/v1/metros", &.{
        .{ .name = "state", .value = "TX" },
        .{ .name = "q", .value = null },
        .{ .name = "per_page", .value = "100" },
    });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("https://getcadastre.com/api/v1/metros?state=TX&per_page=100", got);

    const bare = try build(testing.allocator, "http://127.0.0.1:3000", "/api/v1/me", &.{.{ .name = "q", .value = null }});
    defer testing.allocator.free(bare);
    try testing.expectEqualStrings("http://127.0.0.1:3000/api/v1/me", bare);
}

test "the token request body is form-encoded" {
    const got = try query(testing.allocator, &.{
        .{ .name = "grant_type", .value = "authorization_code" },
        .{ .name = "redirect_uri", .value = "http://127.0.0.1:53682/callback" },
        .{ .name = "resource", .value = "https://getcadastre.com/api/v1" },
    });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("grant_type=authorization_code&redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2Fcallback&resource=https%3A%2F%2Fgetcadastre.com%2Fapi%2Fv1", got);
}

test "normalizeBase trims and checks the scheme" {
    try testing.expectEqualStrings("https://getcadastre.com", try normalizeBase("https://getcadastre.com/"));
    try testing.expectEqualStrings("http://127.0.0.1:3000", try normalizeBase(" http://127.0.0.1:3000 "));
    try testing.expectError(error.InvalidBaseUrl, normalizeBase("getcadastre.com"));
    try testing.expectError(error.InvalidBaseUrl, normalizeBase("ftp://getcadastre.com"));
    try testing.expectError(error.InvalidBaseUrl, normalizeBase("https://"));
    try testing.expectError(error.InvalidBaseUrl, normalizeBase("https://x.com/?a=1"));
}

test "queryValue decodes the redirect's parameters" {
    const q = "code=abc%2Ddef&state=s+1&iss=http%3A%2F%2F127.0.0.1%3A3000&empty=";
    const code = (try queryValue(testing.allocator, q, "code")).?;
    defer testing.allocator.free(code);
    try testing.expectEqualStrings("abc-def", code);
    const state = (try queryValue(testing.allocator, q, "state")).?;
    defer testing.allocator.free(state);
    try testing.expectEqualStrings("s 1", state);
    const iss = (try queryValue(testing.allocator, q, "iss")).?;
    defer testing.allocator.free(iss);
    try testing.expectEqualStrings("http://127.0.0.1:3000", iss);
    const empty = (try queryValue(testing.allocator, q, "empty")).?;
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);
    try testing.expect((try queryValue(testing.allocator, q, "error")) == null);
}

test "decode keeps a malformed escape as it is" {
    const got = try decodeAlloc(testing.allocator, "100%zz%4");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("100%zz%4", got);
}
