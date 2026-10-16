//! What every command runs with: the allocator (an arena: the process is
//! short-lived), I/O, the environment, the output streams and the global
//! flags. Errors are printed here once and the command returns
//! error.Reported, so the exit code says what kind of failure it was.
const App = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

gpa: Allocator,
io: Io,
env: *const std.process.Environ.Map,
out: *Io.Writer,
err: *Io.Writer,
/// ANSI colour on stdout / stderr.
color: bool,
err_color: bool,
json: bool,
/// The site the CLI talks to, without a trailing slash (--base-url,
/// CADASTRE_BASE_URL, else production).
base_url: []const u8,
exit_code: ExitCode = .ok,
/// The API's own error code (`not_found`, `invalid_request`, ...) for the
/// JSON error, when the failure is the API's answer.
error_code: ?[]const u8 = null,
http_client: ?*std.http.Client = null,

pub const default_base_url = "https://getcadastre.com";

/// Documented in README § Exit codes.
pub const ExitCode = enum(u8) {
    ok = 0,
    failure = 1,
    usage = 2,
    /// Not signed in, or the sign-in no longer works: run `cadastre login`.
    auth = 3,
    /// The account must accept the current Terms on the site first.
    terms = 4,
    /// Over a rate limit: try again after Retry-After.
    rate_limited = 5,
};

pub const Error = error{Reported};

/// Prints `message` (to stderr; as `{"error","message"}` JSON under --json)
/// and returns error.Reported with `code` recorded as the exit code.
pub fn fail(app: *App, code: ExitCode, comptime fmt: []const u8, args: anytype) Error {
    app.exit_code = code;
    const message = std.fmt.allocPrint(app.gpa, fmt, args) catch "out of memory";
    if (app.json) {
        const kind = switch (code) {
            .ok, .failure => "error",
            .usage => "usage",
            .auth => "unauthorized",
            .terms => "terms_required",
            .rate_limited => "rate_limited",
        };
        std.json.Stringify.value(.{ .@"error" = app.error_code orelse kind, .message = message }, .{}, app.err) catch {};
        app.err.writeByte('\n') catch {};
    } else {
        app.styleErr("31;1", "error:");
        app.err.print(" {s}\n", .{message}) catch {};
    }
    app.err.flush() catch {};
    return error.Reported;
}

/// A note on stderr (progress, hints), never on stdout so piping stays clean.
pub fn note(app: *App, comptime fmt: []const u8, args: anytype) void {
    app.err.print(fmt ++ "\n", args) catch {};
    app.err.flush() catch {};
}

fn styleErr(app: *App, code: []const u8, text: []const u8) void {
    if (app.err_color) {
        app.err.print("\x1b[{s}m{s}\x1b[0m", .{ code, text }) catch {};
    } else {
        app.err.writeAll(text) catch {};
    }
}

/// The environment variable, or null when unset or empty.
pub fn getenv(app: *const App, name: []const u8) ?[]const u8 {
    const v = app.env.get(name) orelse return null;
    return if (v.len == 0) null else v;
}

/// One HTTP client for the process (keep-alive between the calls of one
/// command; proxies from HTTPS_PROXY/HTTP_PROXY/ALL_PROXY).
pub fn client(app: *App) *std.http.Client {
    if (app.http_client) |c| return c;
    const c = app.gpa.create(std.http.Client) catch @panic("out of memory");
    c.* = .{ .allocator = app.gpa, .io = app.io };
    c.initDefaultProxies(app.gpa, app.env) catch {};
    app.http_client = c;
    return c;
}

pub fn deinit(app: *App) void {
    if (app.http_client) |c| c.deinit();
}

/// Seconds since the epoch.
pub fn now(app: *const App) i64 {
    return Io.Timestamp.now(app.io, .real).toSeconds();
}
