//! Signing in: OAuth 2.1 for a public client against Cadastre's
//! authorization server (discovered from /.well-known/oauth-authorization-server,
//! RFC 8414).
//!
//! - Browser (default): authorization code + PKCE S256, the redirect caught
//!   on a loopback listener at http://127.0.0.1:<free port>/callback
//!   (RFC 8252 § 7.3: the CLI client registered http://127.0.0.1/callback and
//!   any port matches). `state` and the RFC 9207 `iss` are checked.
//! - Device (`--device`, RFC 8628): a code typed at /oauth/device on any
//!   signed-in browser, for machines with no browser.
//!
//! Tokens are bound to the API (RFC 8707 `resource` = <issuer>/api/v1). A
//! refresh rotates the refresh token, and the newest pair is saved at once:
//! presenting a rotated one again would revoke the whole sign-in.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const App = @import("App.zig");
const http = @import("http.zig");
const url = @import("url.zig");
const pkce = @import("pkce.zig");
const store = @import("store.zig");
const api = @import("api.zig");
const jv = @import("json_value.zig");

/// The Cadastre CLI's first-party public OAuth client on getcadastre.com
/// (`bin/rails oauth:cli_client`). Not a secret. Another server (a local
/// one) has its own: set CADASTRE_CLIENT_ID or pass --client-id.
pub const production_client_id = "01a1439d-5c60-7b25-bb0b-cae67bd361aa";
pub const scope = "read";
pub const device_grant = "urn:ietf:params:oauth:grant-type:device_code";

pub const Metadata = struct {
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    revocation_endpoint: ?[]const u8 = null,
    device_authorization_endpoint: ?[]const u8 = null,
    code_challenge_methods_supported: []const []const u8 = &.{},
};

pub const TokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8 = "Bearer",
    expires_in: ?i64 = null,
    refresh_token: ?[]const u8 = null,
    scope: ?[]const u8 = null,
};

pub const DeviceAuthorization = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    verification_uri_complete: ?[]const u8 = null,
    expires_in: i64 = 600,
    interval: ?i64 = null,
};

const parse_options: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

pub fn clientId(app: *App, flag: ?[]const u8) []const u8 {
    return flag orelse app.getenv("CADASTRE_CLIENT_ID") orelse production_client_id;
}

/// The resource the tokens are for: the API under the issuer.
pub fn resource(gpa: std.mem.Allocator, issuer: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ std.mem.trimEnd(u8, issuer, "/"), api.api_path });
}

pub fn discover(app: *App) App.Error!Metadata {
    const where = std.fmt.allocPrint(app.gpa, "{s}/.well-known/oauth-authorization-server", .{app.base_url}) catch return oom(app);
    const res = try http.send(app, .{ .url = where });
    if (!res.ok()) return app.fail(.failure, "{s} answered HTTP {d}; is it a Cadastre server?", .{ where, res.status });
    const md = std.json.parseFromSliceLeaky(Metadata, app.gpa, res.body, parse_options) catch
        return app.fail(.failure, "{s} is not valid OAuth metadata", .{where});
    for (md.code_challenge_methods_supported) |m| {
        if (std.mem.eql(u8, m, "S256")) break;
    } else if (md.code_challenge_methods_supported.len > 0) {
        return app.fail(.failure, "the server does not support PKCE S256", .{});
    }
    return md;
}

fn oom(app: *App) App.Error {
    return app.fail(.failure, "out of memory", .{});
}

/// POSTs a form to the token endpoint; the parsed tokens, or the OAuth error.
const TokenResult = union(enum) {
    tokens: TokenResponse,
    oauth_error: struct { code: []const u8, description: []const u8, status: u16, retry_after: ?[]const u8 },
};

fn tokenRequest(app: *App, endpoint: []const u8, params: []const url.Param) App.Error!TokenResult {
    const body = url.query(app.gpa, params) catch return oom(app);
    const res = try http.send(app, .{ .method = .POST, .url = endpoint, .body = body, .content_type = "application/x-www-form-urlencoded" });
    if (res.ok()) {
        const t = std.json.parseFromSliceLeaky(TokenResponse, app.gpa, res.body, parse_options) catch
            return app.fail(.failure, "the token endpoint's answer was not understood", .{});
        return .{ .tokens = t };
    }
    const e = api.errorBody(app.gpa, res.body);
    return .{ .oauth_error = .{
        .code = e.code orelse "server_error",
        .description = e.message orelse "",
        .status = res.status,
        .retry_after = res.retry_after,
    } };
}

fn saveTokens(app: *App, t: TokenResponse, client_id: []const u8) App.Error!store.Backend {
    const c: store.Credential = .{
        .kind = "oauth",
        .access_token = t.access_token,
        .refresh_token = t.refresh_token,
        .expires_at = if (t.expires_in) |s| app.now() + s else null,
        .client_id = client_id,
        .scope = t.scope,
    };
    return store.save(app, c) catch |err| switch (err) {
        error.Reported => error.Reported,
        error.OutOfMemory => oom(app),
    };
}

/// A fresh access token for `c`, saving the rotated pair. Serialised with
/// other cadastre processes by a lock file; if another one refreshed while we
/// waited, its token is used instead of refreshing again.
pub fn refresh(app: *App, c: store.Credential) App.Error![]const u8 {
    const lock = store.RefreshLock.acquire(app);
    defer lock.release(app);

    if (store.load(app) catch null) |again| {
        const now_c = again.credential;
        if (now_c.isOauth() and now_c.access_token != null and c.access_token != null and
            !std.mem.eql(u8, now_c.access_token.?, c.access_token.?) and
            (now_c.expires_at == null or now_c.expires_at.? - 60 > app.now()))
        {
            return now_c.access_token.?;
        }
    }

    const refresh_token = c.refresh_token orelse
        return app.fail(.auth, "your sign-in to {s} has expired. Run `cadastre login`", .{app.base_url});
    const client_id = c.client_id orelse production_client_id;
    const endpoint = std.fmt.allocPrint(app.gpa, "{s}/oauth/token", .{app.base_url}) catch return oom(app);
    const result = try tokenRequest(app, endpoint, &.{
        .{ .name = "grant_type", .value = "refresh_token" },
        .{ .name = "refresh_token", .value = refresh_token },
        .{ .name = "client_id", .value = client_id },
    });
    switch (result) {
        .tokens => |t| {
            _ = try saveTokens(app, t, client_id);
            return t.access_token;
        },
        .oauth_error => |e| {
            if (std.mem.eql(u8, e.code, "invalid_grant") or std.mem.eql(u8, e.code, "invalid_client")) {
                _ = store.delete(app) catch {};
                return app.fail(.auth, "your sign-in to {s} has expired or was revoked ({s}). Run `cadastre login`", .{ app.base_url, e.description });
            }
            if (e.status == 429) return app.fail(.rate_limited, "rate limited while refreshing the sign-in. Retry after {s} seconds", .{e.retry_after orelse "60"});
            return app.fail(.failure, "could not refresh the sign-in: {s} {s}", .{ e.code, e.description });
        },
    }
}

/// RFC 7009. The server answers 200 whatever the token was.
pub fn revoke(app: *App, token: []const u8, client_id: ?[]const u8) App.Error!bool {
    const endpoint = std.fmt.allocPrint(app.gpa, "{s}/oauth/revoke", .{app.base_url}) catch return oom(app);
    const body = url.query(app.gpa, &.{ .{ .name = "token", .value = token }, .{ .name = "client_id", .value = client_id } }) catch return oom(app);
    const res = try http.send(app, .{ .method = .POST, .url = endpoint, .body = body, .content_type = "application/x-www-form-urlencoded" });
    return res.ok();
}

// ---- browser login --------------------------------------------------------------------------

pub const LoginOptions = struct {
    client_id: []const u8,
    open_browser: bool = true,
};

/// The authorization URL of the browser login.
pub fn authorizationUrl(gpa: std.mem.Allocator, md: Metadata, client_id: []const u8, redirect_uri: []const u8, challenge: []const u8, state: []const u8) std.mem.Allocator.Error![]u8 {
    const q = try url.query(gpa, &.{
        .{ .name = "response_type", .value = "code" },
        .{ .name = "client_id", .value = client_id },
        .{ .name = "redirect_uri", .value = redirect_uri },
        .{ .name = "code_challenge", .value = challenge },
        .{ .name = "code_challenge_method", .value = "S256" },
        .{ .name = "scope", .value = scope },
        .{ .name = "state", .value = state },
        .{ .name = "resource", .value = try resource(gpa, md.issuer) },
    });
    const sep: []const u8 = if (std.mem.indexOfScalar(u8, md.authorization_endpoint, '?') == null) "?" else "&";
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ md.authorization_endpoint, sep, q });
}

pub fn loginBrowser(app: *App, opts: LoginOptions) App.Error!store.Backend {
    const md = try discover(app);
    const secrets = pkce.generate(app.io) catch return app.fail(.failure, "no secure randomness available", .{});
    const challenge = pkce.challenge(&secrets.verifier);

    const address = Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
    var server = address.listen(app.io, .{}) catch |err|
        return app.fail(.failure, "could not listen on 127.0.0.1 for the sign-in redirect: {s}. Try `cadastre login --device`", .{@errorName(err)});
    defer server.deinit(app.io);
    const port = server.socket.address.getPort();
    const redirect_uri = std.fmt.allocPrint(app.gpa, "http://127.0.0.1:{d}/callback", .{port}) catch return oom(app);
    const auth_url = authorizationUrl(app.gpa, md, opts.client_id, redirect_uri, &challenge, &secrets.state) catch return oom(app);

    if (opts.open_browser) {
        app.note("Opening your browser to sign in to {s}.", .{app.base_url});
        app.note("If it does not open, visit this URL:\n\n  {s}\n", .{auth_url});
        if (!openBrowser(app, auth_url)) app.note("(Could not start a browser. On a machine without one, use `cadastre login --device`.)", .{});
    } else {
        app.note("Open this URL in a browser to sign in to {s}:\n\n  {s}\n", .{ app.base_url, auth_url });
    }
    app.note("Waiting for the browser (Ctrl-C to cancel)...", .{});

    const code = try awaitRedirect(app, &server, md.issuer, &secrets.state);
    const result = try tokenRequest(app, md.token_endpoint, &.{
        .{ .name = "grant_type", .value = "authorization_code" },
        .{ .name = "code", .value = code },
        .{ .name = "redirect_uri", .value = redirect_uri },
        .{ .name = "code_verifier", .value = &secrets.verifier },
        .{ .name = "client_id", .value = opts.client_id },
        .{ .name = "resource", .value = resource(app.gpa, md.issuer) catch return oom(app) },
    });
    return switch (result) {
        .tokens => |t| saveTokens(app, t, opts.client_id),
        .oauth_error => |e| app.fail(.auth, "sign-in failed at the token endpoint: {s} {s}", .{ e.code, e.description }),
    };
}

/// What the redirect carried.
pub const Callback = union(enum) {
    code: []const u8,
    /// The person denied, or the server refused the request.
    denied: struct { code: []const u8, description: []const u8 },
    /// Not our redirect (another path, a wrong state): answer and keep waiting.
    ignore: []const u8,
    /// The issuer is not the one we asked (RFC 9207 mix-up defence).
    wrong_issuer,
};

/// Checks a request target (`/callback?code=...&state=...&iss=...`).
pub fn parseCallback(gpa: std.mem.Allocator, target: []const u8, issuer: []const u8, state: []const u8) std.mem.Allocator.Error!Callback {
    const q_at = std.mem.indexOfScalar(u8, target, '?');
    const path = target[0 .. q_at orelse target.len];
    if (!std.mem.eql(u8, path, "/callback")) return .{ .ignore = "Not found." };
    const q = if (q_at) |i| target[i + 1 ..] else "";
    const got_state = try url.queryValue(gpa, q, "state");
    if (got_state == null or !std.mem.eql(u8, got_state.?, state)) return .{ .ignore = "This sign-in link is not the one this terminal is waiting for." };
    if (try url.queryValue(gpa, q, "iss")) |iss| {
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, iss, "/"), std.mem.trimEnd(u8, issuer, "/"))) return .wrong_issuer;
    }
    if (try url.queryValue(gpa, q, "error")) |err| {
        return .{ .denied = .{ .code = err, .description = (try url.queryValue(gpa, q, "error_description")) orelse "" } };
    }
    const code = (try url.queryValue(gpa, q, "code")) orelse return .{ .ignore = "The redirect carried no code." };
    return .{ .code = code };
}

fn awaitRedirect(app: *App, server: *Io.net.Server, issuer: []const u8, state: []const u8) App.Error![]const u8 {
    const io = app.io;
    while (true) {
        var stream = server.accept(io) catch |err| return app.fail(.failure, "the sign-in listener failed: {s}", .{@errorName(err)});
        defer stream.close(io);
        var rbuf: [8192]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        const line = reader.interface.takeDelimiterExclusive('\n') catch continue;
        // Drain the headers; their content does not matter.
        while (reader.interface.takeDelimiterExclusive('\n')) |h| {
            if (std.mem.trim(u8, h, "\r").len == 0) break;
        } else |_| {}
        var parts = std.mem.tokenizeScalar(u8, std.mem.trim(u8, line, "\r"), ' ');
        const method = parts.next() orelse continue;
        const target = parts.next() orelse continue;
        var wbuf: [2048]u8 = undefined;
        var writer = stream.writer(io, &wbuf);
        const w = &writer.interface;
        if (!std.mem.eql(u8, method, "GET")) {
            respond(w, "405 Method Not Allowed", "Only GET.") catch {};
            continue;
        }
        const cb = parseCallback(app.gpa, target, issuer, state) catch return oom(app);
        switch (cb) {
            .ignore => |why| {
                respond(w, "404 Not Found", why) catch {};
                continue;
            },
            .wrong_issuer => {
                respond(w, "400 Bad Request", "The sign-in came from an unexpected server. Return to the terminal.") catch {};
                return app.fail(.auth, "the redirect named a different issuer than {s}; sign-in aborted", .{issuer});
            },
            .denied => |d| {
                respond(w, "200 OK", "Sign-in was not completed. You can close this tab and return to the terminal.") catch {};
                if (std.mem.eql(u8, d.code, "access_denied")) return app.fail(.auth, "sign-in was denied in the browser", .{});
                return app.fail(.auth, "sign-in failed: {s} {s}", .{ d.code, d.description });
            },
            .code => |code| {
                respond(w, "200 OK", "Signed in to Cadastre. You can close this tab and return to the terminal.") catch {};
                return code;
            },
        }
    }
}

fn respond(w: *Io.Writer, status: []const u8, message: []const u8) Io.Writer.Error!void {
    const html_head = "<!doctype html><html><head><meta charset=\"utf-8\"><title>Cadastre CLI</title>" ++
        "<style>body{font:16px system-ui,sans-serif;margin:15vh auto;max-width:32rem;padding:0 1rem;color:#1d2433}</style></head><body><p>";
    const html_tail = "</p></body></html>";
    try w.print("HTTP/1.1 {s}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n", .{ status, html_head.len + message.len + html_tail.len });
    try w.writeAll(html_head);
    try w.writeAll(message);
    try w.writeAll(html_tail);
    try w.flush();
}

/// Opens `target` in the default browser ($BROWSER when set). False when no
/// opener could be started.
pub fn openBrowser(app: *App, target: []const u8) bool {
    const argv: []const []const u8 = if (app.getenv("BROWSER")) |b|
        &.{ b, target }
    else switch (builtin.os.tag) {
        .macos => &.{ "open", target },
        .windows => &.{ "rundll32", "url.dll,FileProtocolHandler", target },
        else => &.{ "xdg-open", target },
    };
    var child = std.process.spawn(app.io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return false;
    const term = child.wait(app.io) catch return false;
    return switch (term) {
        .exited => |c| c == 0,
        else => false,
    };
}

// ---- device login ---------------------------------------------------------------------------

pub fn loginDevice(app: *App, opts: LoginOptions) App.Error!store.Backend {
    const md = try discover(app);
    const endpoint = md.device_authorization_endpoint orelse
        return app.fail(.failure, "{s} does not offer the device flow; use `cadastre login` in a browser or `cadastre login --key`", .{app.base_url});
    const body = url.query(app.gpa, &.{
        .{ .name = "client_id", .value = opts.client_id },
        .{ .name = "scope", .value = scope },
        .{ .name = "resource", .value = resource(app.gpa, md.issuer) catch return oom(app) },
    }) catch return oom(app);
    const res = try http.send(app, .{ .method = .POST, .url = endpoint, .body = body, .content_type = "application/x-www-form-urlencoded" });
    if (!res.ok()) {
        const e = api.errorBody(app.gpa, res.body);
        if (res.status == 429) return app.fail(.rate_limited, "too many device sign-ins; retry after {s} seconds", .{res.retry_after orelse "60"});
        return app.fail(.auth, "the device sign-in could not start: {s} {s}", .{ e.code orelse "", e.message orelse "" });
    }
    const da = std.json.parseFromSliceLeaky(DeviceAuthorization, app.gpa, res.body, parse_options) catch
        return app.fail(.failure, "the device authorization answer was not understood", .{});

    app.note("To sign in, open this page on any device where you are signed in to Cadastre:\n\n  {s}\n\nand enter the code:\n\n  {s}\n", .{ da.verification_uri, da.user_code });
    app.note("Only enter a code you started yourself. The code expires in {d} minutes. Waiting...", .{@divTrunc(da.expires_in + 59, 60)});

    var interval: i64 = da.interval orelse 5;
    const deadline = app.now() + da.expires_in;
    while (app.now() < deadline) {
        app.io.sleep(.fromSeconds(interval), .awake) catch return app.fail(.failure, "cancelled", .{});
        const result = try tokenRequest(app, md.token_endpoint, &.{
            .{ .name = "grant_type", .value = device_grant },
            .{ .name = "device_code", .value = da.device_code },
            .{ .name = "client_id", .value = opts.client_id },
        });
        switch (result) {
            .tokens => |t| return saveTokens(app, t, opts.client_id),
            .oauth_error => |e| {
                if (std.mem.eql(u8, e.code, "authorization_pending")) continue;
                if (std.mem.eql(u8, e.code, "slow_down")) {
                    interval += 5;
                    continue;
                }
                if (std.mem.eql(u8, e.code, "access_denied")) return app.fail(.auth, "the sign-in was denied", .{});
                if (std.mem.eql(u8, e.code, "expired_token")) return app.fail(.auth, "the code expired. Run `cadastre login --device` again", .{});
                return app.fail(.auth, "device sign-in failed: {s} {s}", .{ e.code, e.description });
            },
        }
    }
    return app.fail(.auth, "the code expired. Run `cadastre login --device` again", .{});
}

const testing = std.testing;

fn fixture(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "test/fixtures/{s}", .{name});
    return Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1 << 20));
}

test "the authorization server metadata decodes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const md = try std.json.parseFromSliceLeaky(Metadata, gpa, try fixture(gpa, "metadata.json"), parse_options);
    try testing.expect(std.mem.endsWith(u8, md.token_endpoint, "/oauth/token"));
    try testing.expect(std.mem.endsWith(u8, md.device_authorization_endpoint.?, "/oauth/device_authorization"));
    try testing.expectEqualStrings("S256", md.code_challenge_methods_supported[0]);
}

test "token and device answers decode" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const t = try std.json.parseFromSliceLeaky(TokenResponse, gpa, try fixture(gpa, "token.json"), parse_options);
    try testing.expect(std.mem.startsWith(u8, t.access_token, "cad_at_"));
    try testing.expect(std.mem.startsWith(u8, t.refresh_token.?, "cad_rt_"));
    try testing.expectEqual(@as(?i64, 3600), t.expires_in);
    const d = try std.json.parseFromSliceLeaky(DeviceAuthorization, gpa, try fixture(gpa, "device_authorization.json"), parse_options);
    try testing.expectEqualStrings("BCDF-GHJK", d.user_code);
    try testing.expectEqual(@as(?i64, 5), d.interval);
}

test "the authorization URL carries PKCE, state, scope and resource" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const md: Metadata = .{ .issuer = "https://getcadastre.com", .authorization_endpoint = "https://getcadastre.com/oauth/authorize", .token_endpoint = "https://getcadastre.com/oauth/token" };
    const got = try authorizationUrl(gpa, md, production_client_id, "http://127.0.0.1:53682/callback", "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "st4te");
    try testing.expectEqualStrings("https://getcadastre.com/oauth/authorize?response_type=code&client_id=01a1439d-5c60-7b25-bb0b-cae67bd361aa" ++
        "&redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2Fcallback&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM" ++
        "&code_challenge_method=S256&scope=read&state=st4te&resource=https%3A%2F%2Fgetcadastre.com%2Fapi%2Fv1", got);
}

test "the redirect is checked for path, state, issuer and errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const iss = "https://getcadastre.com";
    const ok = try parseCallback(gpa, "/callback?code=abc&state=s1&iss=https%3A%2F%2Fgetcadastre.com", iss, "s1");
    try testing.expectEqualStrings("abc", ok.code);
    try testing.expect(try parseCallback(gpa, "/favicon.ico", iss, "s1") == .ignore);
    try testing.expect(try parseCallback(gpa, "/callback?code=abc&state=other", iss, "s1") == .ignore);
    try testing.expect(try parseCallback(gpa, "/callback?code=abc", iss, "s1") == .ignore);
    try testing.expect(try parseCallback(gpa, "/callback?code=abc&state=s1&iss=https%3A%2F%2Fevil.example", iss, "s1") == .wrong_issuer);
    const denied = try parseCallback(gpa, "/callback?error=access_denied&error_description=The+request+was+denied.&state=s1&iss=https%3A%2F%2Fgetcadastre.com", iss, "s1");
    try testing.expectEqualStrings("access_denied", denied.denied.code);
    try testing.expectEqualStrings("The request was denied.", denied.denied.description);
    // No iss (a server without RFC 9207) is accepted.
    try testing.expect(try parseCallback(gpa, "/callback?code=abc&state=s1", iss, "s1") == .code);
}

test "the resource is the API under the issuer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("https://getcadastre.com/api/v1", try resource(arena.allocator(), "https://getcadastre.com/"));
}
