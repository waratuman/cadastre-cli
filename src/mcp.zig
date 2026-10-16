//! `cadastre mcp`: connect an AI assistant to Cadastre's remote MCP server
//! (<base>/mcp, streamable HTTP). The assistant signs in itself, through the
//! browser, on first use (OAuth with dynamic registration): no API key is
//! written anywhere.
//!
//! By default the exact command or JSON is printed and nothing is changed.
//! With --write the client's config file is edited: the file is backed up
//! first (<file>.bak-<unix time>) and only the "cadastre" entry is added.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Io = std.Io;
const App = @import("App.zig");
const args = @import("args.zig");

pub const Client = enum {
    claude_code,
    codex,
    cursor,
    vscode,

    pub fn name(c: Client) []const u8 {
        return switch (c) {
            .claude_code => "claude-code",
            .codex => "codex",
            .cursor => "cursor",
            .vscode => "vscode",
        };
    }

    pub fn title(c: Client) []const u8 {
        return switch (c) {
            .claude_code => "Claude Code",
            .codex => "OpenAI Codex CLI",
            .cursor => "Cursor",
            .vscode => "VS Code (GitHub Copilot)",
        };
    }
};

pub fn parseClient(raw: []const u8) ?Client {
    const table = [_]struct { []const u8, Client }{
        .{ "claude-code", .claude_code }, .{ "claude", .claude_code }, .{ "claudecode", .claude_code },
        .{ "codex", .codex },             .{ "cursor", .cursor },      .{ "vscode", .vscode },
        .{ "code", .vscode },             .{ "vs-code", .vscode },     .{ "copilot", .vscode },
    };
    for (table) |alias| if (std.ascii.eqlIgnoreCase(raw, alias[0])) return alias[1];
    return null;
}

pub const server_name = "cadastre";

pub fn serverUrl(gpa: Allocator, base_url: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(gpa, "{s}/mcp", .{base_url});
}

/// The one-line command that registers the server with the client's own CLI
/// (null for Cursor, which has none).
pub fn command(gpa: Allocator, client: Client, mcp_url: []const u8) Allocator.Error!?[]const u8 {
    return switch (client) {
        .claude_code => try std.fmt.allocPrint(gpa, "claude mcp add --transport http --scope user {s} {s}", .{ server_name, mcp_url }),
        .codex => try std.fmt.allocPrint(gpa, "codex mcp add {s} --url {s}", .{ server_name, mcp_url }),
        .cursor => null,
        .vscode => try std.fmt.allocPrint(gpa, "code --add-mcp '{{\"name\":\"{s}\",\"type\":\"http\",\"url\":\"{s}\"}}'", .{ server_name, mcp_url }),
    };
}

/// Where the client's command registers the server.
pub fn commandScope(client: Client) []const u8 {
    return switch (client) {
        .claude_code => "for your user",
        .codex => "in ~/.codex/config.toml",
        .cursor => "",
        .vscode => "in your VS Code user profile",
    };
}

/// What to do after adding the server (by command or by file).
pub fn nextStep(client: Client) []const u8 {
    return switch (client) {
        .claude_code => "start `claude`, approve the cadastre server if asked, then run /mcp and sign in",
        .codex => "codex mcp login " ++ server_name,
        .cursor, .vscode => "reload the editor; it signs in through your browser the first time it uses Cadastre",
    };
}

/// The MCP server, like the API, needs an account with API access enabled.
pub const api_access_note = "Your Cadastre account needs API access. If the assistant reports\n" ++
    "`api_access_required` (HTTP 403), ask support@getcadastre.com to enable it.\n";

/// Where --write puts the entry.
pub const Target = struct {
    path: []const u8,
    /// JSON: the object holding the servers ("mcpServers").
    /// TOML (Codex): null.
    container: ?[]const u8,
    scope: []const u8,
};

pub fn target(app: *App, client: Client) App.Error!Target {
    const gpa = app.gpa;
    const home = app.getenv("HOME") orelse app.getenv("USERPROFILE") orelse
        return app.fail(.failure, "HOME is not set", .{});
    return switch (client) {
        // Project scope: .mcp.json in this directory, which Claude Code reads
        // and offers to enable (user scope is `claude mcp add --scope user`).
        .claude_code => .{ .path = ".mcp.json", .container = "mcpServers", .scope = "this project (.mcp.json)" },
        .codex => .{
            .path = std.fs.path.join(gpa, &.{ app.getenv("CODEX_HOME") orelse (std.fs.path.join(gpa, &.{ home, ".codex" }) catch return oom(app)), "config.toml" }) catch return oom(app),
            .container = null,
            .scope = "your user (Codex config.toml)",
        },
        .cursor => .{ .path = std.fs.path.join(gpa, &.{ home, ".cursor", "mcp.json" }) catch return oom(app), .container = "mcpServers", .scope = "your user (~/.cursor/mcp.json)" },
        // Workspace scope: .mcp.json at the workspace root, the portable file
        // VS Code now prefers (.vscode/mcp.json is deprecated). It has the
        // same shape as Claude Code's, so both read one entry.
        .vscode => .{ .path = ".mcp.json", .container = "mcpServers", .scope = "this workspace (.mcp.json)" },
    };
}

fn oom(app: *App) App.Error {
    return app.fail(.failure, "out of memory", .{});
}

/// The server's entry as the client's config spells it.
pub fn entry(gpa: Allocator, client: Client, mcp_url: []const u8) Allocator.Error!Value {
    var o: std.json.ObjectMap = .empty;
    switch (client) {
        .claude_code, .vscode => {
            try o.put(gpa, "type", .{ .string = "http" });
            try o.put(gpa, "url", .{ .string = mcp_url });
        },
        .cursor, .codex => try o.put(gpa, "url", .{ .string = mcp_url }),
    }
    return .{ .object = o };
}

/// The config snippet: JSON for most, TOML for Codex.
pub fn snippet(gpa: Allocator, client: Client, mcp_url: []const u8) Allocator.Error![]const u8 {
    if (client == .codex) return std.fmt.allocPrint(gpa, "[mcp_servers.{s}]\nurl = \"{s}\"\n", .{ server_name, mcp_url });
    var servers: std.json.ObjectMap = .empty;
    try servers.put(gpa, server_name, try entry(gpa, client, mcp_url));
    var root: std.json.ObjectMap = .empty;
    try root.put(gpa, "mcpServers", .{ .object = servers });
    return std.json.Stringify.valueAlloc(gpa, Value{ .object = root }, .{ .whitespace = .indent_2 });
}

pub const MergeResult = union(enum) {
    /// The new file contents.
    updated: []const u8,
    already: void,
    /// The existing entry points elsewhere; left alone.
    conflict: []const u8,
    invalid: []const u8,
};

/// Adds the entry to a JSON config, keeping everything else.
pub fn mergeJson(gpa: Allocator, existing: ?[]const u8, container: []const u8, client: Client, mcp_url: []const u8) Allocator.Error!MergeResult {
    var root: Value = .{ .object = .empty };
    if (existing) |text| {
        if (std.mem.trim(u8, text, " \r\n\t").len > 0) {
            root = std.json.parseFromSliceLeaky(Value, gpa, text, .{}) catch
                return .{ .invalid = "is not plain JSON (comments or trailing commas?)" };
            if (root != .object) return .{ .invalid = "is not a JSON object" };
        }
    }
    const servers_ptr = try root.object.getOrPut(gpa, container);
    if (!servers_ptr.found_existing) servers_ptr.value_ptr.* = .{ .object = .empty };
    if (servers_ptr.value_ptr.* != .object) return .{ .invalid = "has a non-object server list" };
    const servers = &servers_ptr.value_ptr.object;
    if (servers.get(server_name)) |current| {
        const current_url = switch (current) {
            .object => |o| if (o.get("url")) |u| switch (u) {
                .string => |s| s,
                else => "",
            } else "",
            else => "",
        };
        if (std.mem.eql(u8, current_url, mcp_url)) return .already;
        return .{ .conflict = current_url };
    }
    try servers.put(gpa, server_name, try entry(gpa, client, mcp_url));
    const text = try std.json.Stringify.valueAlloc(gpa, root, .{ .whitespace = .indent_2 });
    return .{ .updated = try std.fmt.allocPrint(gpa, "{s}\n", .{text}) };
}

/// Appends the Codex table unless one named cadastre is already there.
pub fn mergeToml(gpa: Allocator, existing: ?[]const u8, mcp_url: []const u8) Allocator.Error!MergeResult {
    const text = existing orelse "";
    const header = "[mcp_servers." ++ server_name ++ "]";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), header)) {
            if (std.mem.indexOf(u8, text, mcp_url) != null) return .already;
            return .{ .conflict = "an existing [mcp_servers.cadastre] table" };
        }
    }
    const sep: []const u8 = if (text.len == 0) "" else if (std.mem.endsWith(u8, text, "\n\n")) "" else if (std.mem.endsWith(u8, text, "\n")) "\n" else "\n\n";
    return .{ .updated = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ text, sep, try snippet(gpa, .codex, mcp_url) }) };
}

pub fn run(app: *App, rest: []const []const u8) App.Error!void {
    var diag: args.Diagnostic = .{};
    const o = args.parse(app.gpa, rest, &.{.{ .name = "write" }}, &diag) catch |err| switch (err) {
        error.Usage => return app.fail(.usage, "{s}", .{diag.message}),
        error.OutOfMemory => return oom(app),
    };
    const sub = if (o.positionals.len > 0) o.positionals[0] else "list";
    const mcp_url = serverUrl(app.gpa, app.base_url) catch return oom(app);
    if (std.mem.eql(u8, sub, "list") or std.mem.eql(u8, sub, "url")) {
        if (app.json) {
            out(app, std.json.Stringify.value(.{ .url = mcp_url, .clients = [_][]const u8{ "claude-code", "codex", "cursor", "vscode" } }, .{}, app.out));
            out(app, app.out.writeByte('\n'));
            return;
        }
        out(app, app.out.print("Cadastre's MCP server: {s}\n\nConnect an assistant:\n", .{mcp_url}));
        for (std.enums.values(Client)) |c| out(app, app.out.print("  cadastre mcp add {s: <12} {s}\n", .{ c.name(), c.title() }));
        out(app, app.out.writeAll("\nThe assistant signs in through your browser the first time it uses Cadastre.\n"));
        out(app, app.out.writeAll(api_access_note));
        return;
    }
    if (!std.mem.eql(u8, sub, "add")) return app.fail(.usage, "unknown `cadastre mcp` command \"{s}\" (use `cadastre mcp add <client>`)", .{sub});
    if (o.positionals.len != 2) return app.fail(.usage, "usage: cadastre mcp add <claude-code|codex|cursor|vscode> [--write]", .{});
    const client = parseClient(o.positionals[1]) orelse
        return app.fail(.usage, "unknown client \"{s}\": choose claude-code, codex, cursor or vscode", .{o.positionals[1]});
    const cmd = command(app.gpa, client, mcp_url) catch return oom(app);
    const snip = snippet(app.gpa, client, mcp_url) catch return oom(app);
    const where = try target(app, client);

    if (!o.has("write")) {
        if (app.json) {
            out(app, std.json.Stringify.value(.{ .client = client.name(), .url = mcp_url, .command = cmd, .config_file = where.path, .config = snip, .next_step = nextStep(client) }, .{}, app.out));
            out(app, app.out.writeByte('\n'));
            return;
        }
        out(app, app.out.writeAll(instructions(app.gpa, client, mcp_url, where.path) catch return oom(app)));
        return;
    }
    return write(app, client, where, mcp_url);
}

/// The human-readable `cadastre mcp add <client>`: the command (where the
/// client has one), then the config file alternative.
pub fn instructions(gpa: Allocator, client: Client, mcp_url: []const u8, config_path: []const u8) Allocator.Error![]const u8 {
    var w: Io.Writer.Allocating = .init(gpa);
    writeInstructions(gpa, &w.writer, client, mcp_url, config_path) catch return error.OutOfMemory;
    return w.toOwnedSlice();
}

fn writeInstructions(gpa: Allocator, o: *Io.Writer, client: Client, mcp_url: []const u8, config_path: []const u8) (Io.Writer.Error || Allocator.Error)!void {
    const snip = try snippet(gpa, client, mcp_url);
    try o.print("{s}: add Cadastre's MCP server ({s})\n\n", .{ client.title(), mcp_url });
    if (try command(gpa, client, mcp_url)) |cmd| {
        try o.print("Run (adds it {s}):\n\n  {s}\n\nOr put this in {s}:\n\n{s}\n", .{ commandScope(client), cmd, config_path, snip });
    } else {
        try o.print("{s} has no command for this. Put this in {s}:\n\n{s}\n", .{ client.title(), config_path, snip });
    }
    if (client == .vscode or client == .claude_code)
        try o.writeAll("\nClaude Code and VS Code both read this .mcp.json (at the project root).\n");
    try o.print("\nThen: {s}\n", .{nextStep(client)});
    try o.print("\n`cadastre mcp add {s} --write` edits {s} for you (with a backup).\n\n", .{ client.name(), config_path });
    try o.writeAll(api_access_note);
}

fn out(app: *App, result: anytype) void {
    _ = app;
    result catch {};
}

fn write(app: *App, client: Client, where: Target, mcp_url: []const u8) App.Error!void {
    const io = app.io;
    const cwd = Io.Dir.cwd();
    const existing: ?[]const u8 = cwd.readFileAlloc(io, where.path, app.gpa, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return app.fail(.failure, "could not read {s}: {s}", .{ where.path, @errorName(err) }),
    };
    const result = (if (where.container) |container|
        mergeJson(app.gpa, existing, container, client, mcp_url)
    else
        mergeToml(app.gpa, existing, mcp_url)) catch return oom(app);
    switch (result) {
        .already => {
            out(app, app.out.print("{s} already has Cadastre's MCP server ({s}). Nothing changed.\n", .{ where.path, mcp_url }));
            return;
        },
        .conflict => |current| return app.fail(.failure, "{s} already has a \"{s}\" server ({s}); not changed. Edit it by hand to point at {s}", .{ where.path, server_name, current, mcp_url }),
        .invalid => |why| return app.fail(.failure, "{s} {s}; not changed. Add this by hand:\n{s}", .{ where.path, why, snippet(app.gpa, client, mcp_url) catch "" }),
        .updated => |text| {
            var backup: ?[]const u8 = null;
            if (existing) |old| {
                const b = std.fmt.allocPrint(app.gpa, "{s}.bak-{d}", .{ where.path, app.now() }) catch return oom(app);
                cwd.writeFile(io, .{ .sub_path = b, .data = old }) catch |err| return app.fail(.failure, "could not back up {s} to {s}: {s}; not changed", .{ where.path, b, @errorName(err) });
                backup = b;
            } else if (std.fs.path.dirname(where.path)) |dir| {
                cwd.createDirPath(io, dir) catch |err| return app.fail(.failure, "could not create {s}: {s}", .{ dir, @errorName(err) });
            }
            cwd.writeFile(io, .{ .sub_path = where.path, .data = text }) catch |err|
                return app.fail(.failure, "could not write {s}: {s}", .{ where.path, @errorName(err) });
            out(app, app.out.print("Added Cadastre's MCP server ({s}) for {s}: {s}.\n", .{ mcp_url, where.scope, where.path }));
            if (backup) |b| out(app, app.out.print("Backup of the previous file: {s}\n", .{b}));
            out(app, app.out.print("Next: {s}\n", .{nextStep(client)}));
            out(app, app.out.writeAll(api_access_note));
        },
    }
}

const testing = std.testing;

test "client names and aliases" {
    try testing.expectEqual(Client.claude_code, parseClient("claude-code").?);
    try testing.expectEqual(Client.claude_code, parseClient("Claude").?);
    try testing.expectEqual(Client.vscode, parseClient("code").?);
    try testing.expect(parseClient("emacs") == null);
}

test "the printed commands" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const u = "https://getcadastre.com/mcp";
    try testing.expectEqualStrings("claude mcp add --transport http --scope user cadastre https://getcadastre.com/mcp", (try command(gpa, .claude_code, u)).?);
    try testing.expectEqualStrings("codex mcp add cadastre --url https://getcadastre.com/mcp", (try command(gpa, .codex, u)).?);
    try testing.expectEqualStrings("code --add-mcp '{\"name\":\"cadastre\",\"type\":\"http\",\"url\":\"https://getcadastre.com/mcp\"}'", (try command(gpa, .vscode, u)).?);
    try testing.expect((try command(gpa, .cursor, u)) == null);
}

test "the printed instructions show the command and the config file, and the API access note" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const u = "https://getcadastre.com/mcp";
    const cases = [_]struct { Client, []const u8, []const []const u8 }{
        .{ .claude_code, ".mcp.json", &.{ "claude mcp add --transport http --scope user cadastre https://getcadastre.com/mcp", "Or put this in .mcp.json", "\"mcpServers\"", "/mcp" } },
        .{ .codex, "/h/.codex/config.toml", &.{ "codex mcp add cadastre --url https://getcadastre.com/mcp", "Then: codex mcp login cadastre", "[mcp_servers.cadastre]" } },
        .{ .vscode, ".mcp.json", &.{ "code --add-mcp '{\"name\":\"cadastre\",\"type\":\"http\",\"url\":\"https://getcadastre.com/mcp\"}'", "Or put this in .mcp.json", "\"mcpServers\"", "\"type\": \"http\"" } },
        .{ .cursor, "/h/.cursor/mcp.json", &.{ "has no command", "Put this in /h/.cursor/mcp.json", "\"mcpServers\"" } },
    };
    for (cases) |case| {
        const text = try instructions(gpa, case[0], u, case[1]);
        for (case[2]) |needle| {
            if (std.mem.indexOf(u8, text, needle) == null) {
                std.debug.print("missing \"{s}\" in:\n{s}\n", .{ needle, text });
                return error.TestExpectedOutput;
            }
        }
        try testing.expect(std.mem.indexOf(u8, text, "api_access_required") != null);
        try testing.expect(std.mem.indexOf(u8, text, "support@getcadastre.com") != null);
    }
}

test "snippets per client" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const u = "https://getcadastre.com/mcp";
    try testing.expectEqualStrings(
        \\{
        \\  "mcpServers": {
        \\    "cadastre": {
        \\      "type": "http",
        \\      "url": "https://getcadastre.com/mcp"
        \\    }
        \\  }
        \\}
    , try snippet(gpa, .claude_code, u));
    // VS Code's workspace .mcp.json: the same shape as Claude Code's.
    try testing.expectEqualStrings(try snippet(gpa, .claude_code, u), try snippet(gpa, .vscode, u));
    try testing.expectEqualStrings("[mcp_servers.cadastre]\nurl = \"https://getcadastre.com/mcp\"\n", try snippet(gpa, .codex, u));
}

test "merging into a JSON config keeps the other servers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const u = "https://getcadastre.com/mcp";
    const existing =
        \\{"theme":"dark","mcpServers":{"other":{"command":"npx","args":["-y","x"]}}}
    ;
    const r = try mergeJson(gpa, existing, "mcpServers", .cursor, u);
    const merged = try std.json.parseFromSliceLeaky(Value, gpa, r.updated, .{});
    try testing.expectEqualStrings("dark", merged.object.get("theme").?.string);
    const servers = merged.object.get("mcpServers").?.object;
    try testing.expect(servers.get("other") != null);
    try testing.expectEqualStrings(u, servers.get("cadastre").?.object.get("url").?.string);

    try testing.expect(try mergeJson(gpa, r.updated, "mcpServers", .cursor, u) == .already);
    try testing.expect(try mergeJson(gpa, r.updated, "mcpServers", .cursor, "http://127.0.0.1:3000/mcp") == .conflict);
    try testing.expect(try mergeJson(gpa, "// comment\n{}", "mcpServers", .cursor, u) == .invalid);
    try testing.expect(try mergeJson(gpa, "[]", "mcpServers", .cursor, u) == .invalid);
    const fresh = try mergeJson(gpa, null, "mcpServers", .vscode, u);
    try testing.expect(std.mem.indexOf(u8, fresh.updated, "\"mcpServers\"") != null);
}

test "Claude Code and VS Code share one .mcp.json without clobbering each other" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const u = "https://getcadastre.com/mcp";
    var env: std.process.Environ.Map = .init(gpa);
    try env.put("HOME", "/h");
    var sink: Io.Writer.Allocating = .init(gpa);
    var app: App = .{ .gpa = gpa, .io = testing.io, .env = &env, .out = &sink.writer, .err = &sink.writer, .color = false, .err_color = false, .json = false, .base_url = App.default_base_url };
    // Both clients write the same file under the same key.
    for ([_]Client{ .claude_code, .vscode }) |c| {
        const t = try target(&app, c);
        try testing.expectEqualStrings(".mcp.json", t.path);
        try testing.expectEqualStrings("mcpServers", t.container.?);
    }

    // Claude Code first, then VS Code: VS Code finds the entry it would add.
    const after_claude = (try mergeJson(gpa, null, "mcpServers", .claude_code, u)).updated;
    try testing.expect(try mergeJson(gpa, after_claude, "mcpServers", .vscode, u) == .already);

    // A project .mcp.json holding other servers and a legacy "servers" object
    // (VS Code's old key): everything is kept, cadastre is added once.
    const existing =
        \\{"mcpServers":{"github":{"type":"http","url":"https://api.githubcopilot.com/mcp"}},"servers":{"legacy":{"command":"npx"}},"inputs":[]}
    ;
    const merged_text = (try mergeJson(gpa, existing, "mcpServers", .vscode, u)).updated;
    const merged = try std.json.parseFromSliceLeaky(Value, gpa, merged_text, .{});
    const servers = merged.object.get("mcpServers").?.object;
    try testing.expect(servers.get("github") != null);
    const cadastre = servers.get("cadastre").?.object;
    try testing.expectEqualStrings("http", cadastre.get("type").?.string);
    try testing.expectEqualStrings(u, cadastre.get("url").?.string);
    try testing.expect(merged.object.get("servers").?.object.get("legacy") != null);
    try testing.expect(merged.object.get("inputs") != null);
    try testing.expect(try mergeJson(gpa, merged_text, "mcpServers", .claude_code, u) == .already);
}

test "merging into Codex's TOML appends one table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const u = "https://getcadastre.com/mcp";
    const r = try mergeToml(gpa, "model = \"o3\"\n", u);
    try testing.expectEqualStrings("model = \"o3\"\n\n[mcp_servers.cadastre]\nurl = \"https://getcadastre.com/mcp\"\n", r.updated);
    try testing.expect(try mergeToml(gpa, r.updated, u) == .already);
    try testing.expect(try mergeToml(gpa, r.updated, "http://x/mcp") == .conflict);
    try testing.expectEqualStrings("[mcp_servers.cadastre]\nurl = \"https://getcadastre.com/mcp\"\n", (try mergeToml(gpa, null, u)).updated);
}
