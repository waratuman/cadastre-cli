//! Calls to the public API (/api/v1) with the current credential: an API key
//! from CADASTRE_API_KEY, else the saved sign-in. An OAuth access token close
//! to expiry is refreshed first, and a 401 is retried once after a refresh.
//! Every failure the API can answer is turned into a message that says what
//! to do (README § Errors and exit codes).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const App = @import("App.zig");
const http = @import("http.zig");
const url = @import("url.zig");
const store = @import("store.zig");
const oauth = @import("oauth.zig");
const jv = @import("json_value.zig");

pub const api_path = "/api/v1";

pub const Origin = enum { env, stored };

pub const Credential = struct {
    token: []const u8,
    origin: Origin,
    /// The saved credential (null for CADASTRE_API_KEY).
    saved: ?store.Loaded = null,
};

/// The credential the next request uses, or an "run cadastre login" error.
pub fn current(app: *App) App.Error!Credential {
    if (app.getenv("CADASTRE_API_KEY")) |key| return .{ .token = key, .origin = .env };
    const loaded = (store.load(app) catch |err| return mapStoreError(app, err)) orelse
        return app.fail(.auth, "not signed in to {s}. Run `cadastre login` (or set CADASTRE_API_KEY)", .{app.base_url});
    const c = loaded.credential;
    if (c.isOauth()) {
        const token = c.access_token orelse return app.fail(.auth, "the saved sign-in is incomplete. Run `cadastre login`", .{});
        return .{ .token = token, .origin = .stored, .saved = loaded };
    }
    const key = c.api_key orelse return app.fail(.auth, "the saved API key is missing. Run `cadastre login --key`", .{});
    return .{ .token = key, .origin = .stored, .saved = loaded };
}

fn mapStoreError(app: *App, err: store.Error) App.Error {
    return switch (err) {
        error.Reported => error.Reported,
        error.OutOfMemory => app.fail(.failure, "out of memory", .{}),
    };
}

/// An answer: the body as sent (for --json) and parsed.
pub const Answer = struct {
    raw: []const u8,
    root: Value,
};

pub fn get(app: *App, path: []const u8, params: []const url.Param) App.Error!Answer {
    const full = url.build(app.gpa, app.base_url, try concat(app, api_path, path), params) catch return oom(app);
    return call(app, .GET, full, null);
}

pub fn post(app: *App, path: []const u8, body: []const u8) App.Error!Answer {
    const full = url.build(app.gpa, app.base_url, try concat(app, api_path, path), &.{}) catch return oom(app);
    return call(app, .POST, full, body);
}

fn concat(app: *App, a: []const u8, b: []const u8) App.Error![]const u8 {
    return std.mem.concat(app.gpa, u8, &.{ a, b }) catch oom(app);
}

fn oom(app: *App) App.Error {
    return app.fail(.failure, "out of memory", .{});
}

/// Seconds of life an access token must have left to be used as it is.
const refresh_margin = 60;

fn call(app: *App, method: std.http.Method, full_url: []const u8, body: ?[]const u8) App.Error!Answer {
    var cred = try current(app);
    var refreshed = false;
    if (cred.saved) |saved| {
        const c = saved.credential;
        if (c.isOauth() and c.expires_at != null and c.expires_at.? - refresh_margin <= app.now()) {
            cred.token = try oauth.refresh(app, c);
            refreshed = true;
        }
    }
    while (true) {
        const res = try http.send(app, .{
            .method = method,
            .url = full_url,
            .bearer = cred.token,
            .body = body,
            .content_type = if (body != null) "application/json" else null,
        });
        if (res.status == 401 and !refreshed and cred.saved != null and cred.saved.?.credential.isOauth()) {
            cred.token = try oauth.refresh(app, cred.saved.?.credential);
            refreshed = true;
            continue;
        }
        if (!res.ok()) return failFor(app, res, cred.origin, full_url);
        const root = std.json.parseFromSliceLeaky(Value, app.gpa, res.body, .{}) catch
            return app.fail(.failure, "the server's answer was not JSON (HTTP {d}); is {s} a Cadastre server?", .{ res.status, app.base_url });
        return .{ .raw = res.body, .root = root };
    }
}

/// The API's `{ error, message }` (or OAuth's `{ error, error_description }`).
pub const ErrorBody = struct { code: ?[]const u8, message: ?[]const u8 };

pub fn errorBody(gpa: Allocator, body: []const u8) ErrorBody {
    const root = std.json.parseFromSliceLeaky(Value, gpa, body, .{}) catch return .{ .code = null, .message = null };
    return .{
        .code = jv.str(root, "error"),
        .message = jv.str(root, "message") orelse jv.str(root, "error_description"),
    };
}

/// Reports a non-2xx answer with the exit code its kind calls for.
pub fn failFor(app: *App, res: http.Response, origin: Origin, request_url: []const u8) App.Error {
    const e = errorBody(app.gpa, res.body);
    const message = e.message orelse "";
    app.error_code = e.code;
    if (e.code == null and res.status != 429) {
        return app.fail(.failure, "{s} answered HTTP {d} without a Cadastre API error; is --base-url (or CADASTRE_BASE_URL) right?", .{ request_url, res.status });
    }
    switch (res.status) {
        401 => {
            if (origin == .env) return app.fail(.auth, "CADASTRE_API_KEY was refused: {s}. Check the key (Settings > API keys) or unset it to use `cadastre login`", .{nonEmpty(message, "not valid")});
            return app.fail(.auth, "your sign-in to {s} is no longer valid ({s}). Run `cadastre login`", .{ app.base_url, nonEmpty(message, "unauthorized") });
        },
        403 => {
            if (e.code != null and std.mem.eql(u8, e.code.?, "terms_required")) {
                return app.fail(.terms, "your account must accept Cadastre's current Terms first. Sign in at {s} and accept them, then try again", .{app.base_url});
            }
            if (e.code != null and std.mem.eql(u8, e.code.?, "api_access_required")) {
                return app.fail(.api_access, "your Cadastre account does not have API access enabled (the CLI and MCP server need it). Ask support@getcadastre.com to enable it", .{});
            }
            if (e.code != null and std.mem.eql(u8, e.code.?, "insufficient_scope")) {
                return app.fail(.auth, "this credential lacks the read scope. Run `cadastre login` again", .{});
            }
            return app.fail(.failure, "forbidden: {s}", .{nonEmpty(message, "the server refused the request")});
        },
        429 => {
            if (res.retry_after) |after| return app.fail(.rate_limited, "rate limited: {s} Retry after {s} seconds", .{ nonEmpty(message, "too many requests."), after });
            return app.fail(.rate_limited, "rate limited: {s}", .{nonEmpty(message, "too many requests; try again later.")});
        },
        404 => return app.fail(.failure, "not found: {s} (it does not exist, or is not served through the API)", .{request_url[app.base_url.len..]}),
        400, 415, 422 => return app.fail(.failure, "the API refused the request: {s}", .{nonEmpty(message, "bad request")}),
        503 => return app.fail(.failure, "the API is unavailable (503): {s}", .{nonEmpty(message, "try again later")}),
        else => return app.fail(.failure, "the server answered HTTP {d}: {s}", .{ res.status, nonEmpty(message, "unexpected error") }),
    }
}

fn nonEmpty(s: []const u8, fallback: []const u8) []const u8 {
    return if (s.len == 0) fallback else s;
}

// The `{ error, message }` of the recorded API errors.
test "error bodies of the API and of the OAuth server are read alike" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const cwd = std.Io.Dir.cwd();
    const e401 = errorBody(gpa, try cwd.readFileAlloc(std.testing.io, "test/fixtures/error_401.json", gpa, .limited(1 << 16)));
    try std.testing.expectEqualStrings("invalid_token", e401.code.?);
    try std.testing.expectEqualStrings("The access token or API key is not valid", e401.message.?);
    const e422 = errorBody(gpa, try cwd.readFileAlloc(std.testing.io, "test/fixtures/error_422.json", gpa, .limited(1 << 16)));
    try std.testing.expect(std.mem.indexOf(u8, e422.message.?, "no_such_measure") != null);
    const eo = errorBody(gpa, try cwd.readFileAlloc(std.testing.io, "test/fixtures/oauth_error.json", gpa, .limited(1 << 16)));
    try std.testing.expectEqualStrings("authorization_pending", eo.code.?);
    try std.testing.expect(eo.message != null);
    const junk = errorBody(gpa, "<html>");
    try std.testing.expect(junk.code == null and junk.message == null);
}
