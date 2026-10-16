//! Where the CLI keeps its sign-in, one per site (base URL), so a local
//! server's credential never replaces production's:
//!
//! - macOS: the login Keychain (generic password, service "cadastre-cli",
//!   account = the base URL), through /usr/bin/security;
//! - Linux: the Secret Service (GNOME Keyring, KWallet) through `secret-tool`
//!   (libsecret) when it is installed and a session bus answers;
//! - otherwise, and when CADASTRE_CREDENTIAL_STORE=file: a JSON file readable
//!   only by you (0600, in a 0700 directory) at
//!   $XDG_CONFIG_HOME/cadastre/credentials.json (~/.config/cadastre/ when
//!   XDG_CONFIG_HOME is unset; %APPDATA%\cadastre\ on Windows).
//!
//! The secret is passed to `security` and `secret-tool` on stdin, never in
//! argv (which other users can read in `ps`). Nothing here prints a token.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const App = @import("App.zig");

pub const service = "cadastre-cli";

pub const Credential = struct {
    /// "api_key" or "oauth".
    kind: []const u8,
    api_key: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    /// When the access token expires, seconds since the epoch.
    expires_at: ?i64 = null,
    /// The OAuth client the tokens were issued to (refresh must name it).
    client_id: ?[]const u8 = null,
    scope: ?[]const u8 = null,

    pub fn isOauth(c: Credential) bool {
        return std.mem.eql(u8, c.kind, "oauth");
    }
};

pub const Backend = enum {
    keychain,
    secret_service,
    file,

    pub fn label(b: Backend) []const u8 {
        return switch (b) {
            .keychain => "macOS Keychain",
            .secret_service => "Secret Service (libsecret)",
            .file => "credentials file",
        };
    }
};

pub const Error = App.Error || Allocator.Error;

/// The backend to use: CADASTRE_CREDENTIAL_STORE, else the platform's.
pub fn preferred(app: *App) Error!Backend {
    if (app.getenv("CADASTRE_CREDENTIAL_STORE")) |raw| {
        if (std.mem.eql(u8, raw, "keychain")) return .keychain;
        if (std.mem.eql(u8, raw, "secret-service") or std.mem.eql(u8, raw, "libsecret")) return .secret_service;
        if (std.mem.eql(u8, raw, "file")) return .file;
        return app.fail(.usage, "CADASTRE_CREDENTIAL_STORE must be keychain, secret-service or file (got \"{s}\")", .{raw});
    }
    return switch (builtin.os.tag) {
        .macos => .keychain,
        .linux, .freebsd, .openbsd, .netbsd => .secret_service,
        else => .file,
    };
}

pub const Loaded = struct { credential: Credential, backend: Backend };

/// The saved credential for the current base URL, from the preferred backend
/// or, failing that, the file (where a Linux machine without a Secret Service
/// falls back to).
pub fn load(app: *App) Error!?Loaded {
    const backend = try preferred(app);
    switch (backend) {
        .keychain, .secret_service => {
            if (try toolLoad(app, backend)) |secret| {
                if (decode(app.gpa, secret)) |c| return .{ .credential = c, .backend = backend };
            }
        },
        .file => {},
    }
    if (try fileLoad(app)) |c| return .{ .credential = c, .backend = .file };
    return null;
}

/// Saves the credential, replacing any for the same base URL. Returns where.
pub fn save(app: *App, c: Credential) Error!Backend {
    const secret = try encode(app.gpa, c);
    const backend = try preferred(app);
    switch (backend) {
        .keychain, .secret_service => {
            if (try toolSave(app, backend, secret)) {
                // Never leave an older copy in the file to be found later.
                _ = fileDelete(app) catch false;
                return backend;
            }
            if (backend == .keychain) {
                return app.fail(.failure, "could not save to the macOS Keychain; set CADASTRE_CREDENTIAL_STORE=file to use a file instead", .{});
            }
        },
        .file => {},
    }
    try fileSave(app, c);
    return .file;
}

/// Removes the credential for the current base URL from every backend.
/// Returns whether one was found.
pub fn delete(app: *App) Error!bool {
    var found = false;
    const backend = try preferred(app);
    if (backend != .file) found = try toolDelete(app, backend);
    if (try fileDelete(app)) found = true;
    return found;
}

// ---- the secret as stored ---------------------------------------------------------------

const Stored = struct {
    version: u32 = 1,
    credential: Credential,
};

/// The credential as JSON, then standard base64 so it is one token with no
/// quotes or spaces in `security -i`'s command line.
pub fn encode(gpa: Allocator, c: Credential) Allocator.Error![]u8 {
    const json = try std.json.Stringify.valueAlloc(gpa, Stored{ .credential = c }, .{ .emit_null_optional_fields = false });
    const enc = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, enc.calcSize(json.len));
    _ = enc.encode(out, json);
    return out;
}

pub fn decode(gpa: Allocator, secret: []const u8) ?Credential {
    const trimmed = std.mem.trim(u8, secret, " \r\n\t");
    const dec = std.base64.standard.Decoder;
    const len = dec.calcSizeForSlice(trimmed) catch return null;
    const json = gpa.alloc(u8, len) catch return null;
    dec.decode(json, trimmed) catch return null;
    const stored = std.json.parseFromSliceLeaky(Stored, gpa, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    return stored.credential;
}

// ---- security / secret-tool ---------------------------------------------------------------

const ToolResult = struct { exited: ?u8, stdout: []const u8, stderr: []const u8 };

/// Runs a helper with `stdin_data` on its stdin; null when the program is
/// not installed.
fn runTool(app: *App, argv: []const []const u8, stdin_data: ?[]const u8) Error!?ToolResult {
    const io = app.io;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (stdin_data != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return null,
        else => return app.fail(.failure, "could not run {s}: {s}", .{ argv[0], @errorName(err) }),
    };
    if (stdin_data) |data| {
        var buf: [512]u8 = undefined;
        var w = child.stdin.?.writerStreaming(io, &buf);
        w.interface.writeAll(data) catch {};
        w.interface.flush() catch {};
        child.stdin.?.close(io);
        child.stdin = null;
    }
    // The helpers print little; read stdout, then stderr, then reap.
    var obuf: [512]u8 = undefined;
    var or_ = child.stdout.?.readerStreaming(io, &obuf);
    const out = or_.interface.allocRemaining(app.gpa, .limited(1 << 20)) catch "";
    var ebuf: [512]u8 = undefined;
    var er = child.stderr.?.readerStreaming(io, &ebuf);
    const err_out = er.interface.allocRemaining(app.gpa, .limited(1 << 20)) catch "";
    const term = child.wait(io) catch return .{ .exited = null, .stdout = out, .stderr = err_out };
    return .{
        .exited = switch (term) {
            .exited => |code| code,
            else => null,
        },
        .stdout = out,
        .stderr = err_out,
    };
}

fn toolLoad(app: *App, backend: Backend) Error!?[]const u8 {
    const argv: []const []const u8 = switch (backend) {
        .keychain => &.{ "/usr/bin/security", "find-generic-password", "-s", service, "-a", app.base_url, "-w" },
        .secret_service => &.{ "secret-tool", "lookup", "service", service, "account", app.base_url },
        .file => unreachable,
    };
    const r = try runTool(app, argv, null) orelse return null;
    if (r.exited != 0 or std.mem.trim(u8, r.stdout, " \r\n").len == 0) return null;
    return r.stdout;
}

fn toolSave(app: *App, backend: Backend, secret: []const u8) Error!bool {
    switch (backend) {
        .keychain => {
            // `security -i` reads its command from stdin, so the secret is
            // not in argv. base_url has no spaces or quotes (url.normalizeBase).
            const command = try std.fmt.allocPrint(app.gpa, "add-generic-password -U -s {s} -a {s} -l \"Cadastre CLI ({s})\" -w {s}\n", .{ service, app.base_url, app.base_url, secret });
            _ = try runTool(app, &.{ "/usr/bin/security", "-i" }, command) orelse return false;
            // `security -i` exits 0 whatever its command did: read it back.
            const back = try toolLoad(app, .keychain) orelse return false;
            return std.mem.eql(u8, std.mem.trim(u8, back, " \r\n"), secret);
        },
        .secret_service => {
            const label = try std.fmt.allocPrint(app.gpa, "--label=Cadastre CLI ({s})", .{app.base_url});
            const r = try runTool(app, &.{ "secret-tool", "store", label, "service", service, "account", app.base_url }, secret) orelse return false;
            return r.exited == 0;
        },
        .file => unreachable,
    }
}

fn toolDelete(app: *App, backend: Backend) Error!bool {
    const argv: []const []const u8 = switch (backend) {
        .keychain => &.{ "/usr/bin/security", "delete-generic-password", "-s", service, "-a", app.base_url },
        .secret_service => &.{ "secret-tool", "clear", "service", service, "account", app.base_url },
        .file => unreachable,
    };
    const had = try toolLoad(app, backend) != null;
    _ = try runTool(app, argv, null);
    return had;
}

// ---- the file ---------------------------------------------------------------------------

/// $XDG_CONFIG_HOME/cadastre, ~/.config/cadastre, or %APPDATA%\cadastre.
pub fn configDir(app: *App) Error![]const u8 {
    if (app.getenv("XDG_CONFIG_HOME")) |xdg| return std.fs.path.join(app.gpa, &.{ xdg, "cadastre" });
    if (builtin.os.tag == .windows) {
        if (app.getenv("APPDATA")) |appdata| return std.fs.path.join(app.gpa, &.{ appdata, "cadastre" });
    }
    if (app.getenv("HOME")) |home| return std.fs.path.join(app.gpa, &.{ home, ".config", "cadastre" });
    return app.fail(.failure, "neither XDG_CONFIG_HOME nor HOME is set: cannot find the config directory", .{});
}

pub fn filePath(app: *App) Error![]const u8 {
    return std.fs.path.join(app.gpa, &.{ try configDir(app), "credentials.json" });
}

const FileContents = struct {
    version: u32 = 1,
    credentials: std.json.ArrayHashMap(Credential) = .{},
};

fn readFile(app: *App) Error!FileContents {
    const path = try filePath(app);
    const bytes = Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return app.fail(.failure, "could not read {s}: {s}", .{ path, @errorName(err) }),
    };
    return std.json.parseFromSliceLeaky(FileContents, app.gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        app.fail(.failure, "{s} is not valid; delete it and run `cadastre login` again", .{path});
}

fn writeFile(app: *App, contents: FileContents) Error!void {
    const dir_path = try configDir(app);
    const path = try filePath(app);
    const io = app.io;
    const cwd = Io.Dir.cwd();
    _ = cwd.createDirPathStatus(io, dir_path, permissions(0o700)) catch |err|
        return app.fail(.failure, "could not create {s}: {s}", .{ dir_path, @errorName(err) });
    const json = try std.json.Stringify.valueAlloc(app.gpa, contents, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    // Written beside, then renamed over, so a crash never leaves half a file.
    const tmp = try std.fmt.allocPrint(app.gpa, "{s}.tmp", .{path});
    {
        var file = cwd.createFile(io, tmp, .{ .permissions = permissions(0o600) }) catch |err|
            return app.fail(.failure, "could not write {s}: {s}", .{ tmp, @errorName(err) });
        defer file.close(io);
        if (builtin.os.tag != .windows) file.setPermissions(io, permissions(0o600)) catch {};
        var buf: [1024]u8 = undefined;
        var w = file.writer(io, &buf);
        w.interface.writeAll(json) catch return app.fail(.failure, "could not write {s}", .{tmp});
        w.interface.flush() catch return app.fail(.failure, "could not write {s}", .{tmp});
    }
    cwd.rename(tmp, cwd, path, io) catch |err| return app.fail(.failure, "could not write {s}: {s}", .{ path, @errorName(err) });
}

fn permissions(mode: u32) Io.File.Permissions {
    if (builtin.os.tag == .windows) return .default_file;
    return .fromMode(@intCast(mode));
}

fn fileLoad(app: *App) Error!?Credential {
    const contents = try readFile(app);
    return contents.credentials.map.get(app.base_url);
}

fn fileSave(app: *App, c: Credential) Error!void {
    var contents = try readFile(app);
    try contents.credentials.map.put(app.gpa, app.base_url, c);
    try writeFile(app, contents);
}

fn fileDelete(app: *App) Error!bool {
    var contents = try readFile(app);
    if (!contents.credentials.map.orderedRemove(app.base_url)) return false;
    try writeFile(app, contents);
    return true;
}

/// Held while refreshing, so two commands running at once do not both
/// present the same refresh token (the second would be treated as a replay
/// and revoke the sign-in).
pub const RefreshLock = struct {
    file: ?Io.File,

    pub fn acquire(app: *App) RefreshLock {
        const dir_path = configDir(app) catch return .{ .file = null };
        const io = app.io;
        _ = Io.Dir.cwd().createDirPathStatus(io, dir_path, permissions(0o700)) catch return .{ .file = null };
        const path = std.fs.path.join(app.gpa, &.{ dir_path, "refresh.lock" }) catch return .{ .file = null };
        const file = Io.Dir.cwd().createFile(io, path, .{ .truncate = false, .lock = .exclusive, .permissions = permissions(0o600) }) catch return .{ .file = null };
        return .{ .file = file };
    }

    pub fn release(l: RefreshLock, app: *App) void {
        if (l.file) |f| f.close(app.io);
    }
};

const testing = std.testing;

test "a credential survives encode and decode, and never as plain text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const c: Credential = .{
        .kind = "oauth",
        .access_token = "cad_at_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        .refresh_token = "cad_rt_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        .expires_at = 1_792_000_000,
        .client_id = "01a1439d-5c60-7b25-bb0b-cae67bd361aa",
    };
    const secret = try encode(gpa, c);
    try testing.expect(std.mem.indexOf(u8, secret, "cad_") == null);
    try testing.expect(std.mem.indexOfAny(u8, secret, " \"'\n") == null);
    const back = decode(gpa, secret).?;
    try testing.expect(back.isOauth());
    try testing.expectEqualStrings(c.refresh_token.?, back.refresh_token.?);
    try testing.expectEqual(c.expires_at, back.expires_at);
    try testing.expect(back.api_key == null);
    // `security -w` prints the secret with a newline.
    const with_newline = try std.fmt.allocPrint(gpa, "{s}\n", .{secret});
    try testing.expect(decode(gpa, with_newline) != null);
    try testing.expect(decode(gpa, "not base64!") == null);
}

test "the credentials file holds one credential per site" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const json =
        \\{"version":1,"credentials":{
        \\  "https://getcadastre.com":{"kind":"api_key","api_key":"cad_key_x"},
        \\  "http://127.0.0.1:3000":{"kind":"oauth","access_token":"cad_at_y","refresh_token":"cad_rt_z","expires_at":5,"future":"ignored"}}}
    ;
    const contents = try std.json.parseFromSliceLeaky(FileContents, gpa, json, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("cad_key_x", contents.credentials.map.get("https://getcadastre.com").?.api_key.?);
    try testing.expect(contents.credentials.map.get("http://127.0.0.1:3000").?.isOauth());
}
