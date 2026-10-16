//! cadastre: the command-line client of Cadastre's public API
//! (https://getcadastre.com/api/v1). README.md is the user's guide.
const std = @import("std");
const Io = std.Io;
const App = @import("App.zig");
const args = @import("args.zig");
const url = @import("url.zig");
const commands = @import("commands.zig");
const mcp = @import("mcp.zig");
const help = @import("help.zig");

const Command = struct {
    name: []const u8,
    run: *const fn (*App, []const []const u8) App.Error!void,
};

const table = [_]Command{
    .{ .name = "login", .run = commands.login },
    .{ .name = "logout", .run = commands.logout },
    .{ .name = "whoami", .run = commands.whoami },
    .{ .name = "datasets", .run = commands.datasets },
    .{ .name = "measures", .run = commands.measures },
    .{ .name = "metro", .run = commands.metro },
    .{ .name = "metros", .run = commands.metros },
    .{ .name = "compare", .run = commands.compare },
    .{ .name = "screen", .run = commands.screen },
    .{ .name = "rank", .run = commands.rank },
    .{ .name = "mcp", .run = mcp.run },
    .{ .name = "docs", .run = commands.docs },
    .{ .name = "version", .run = commands.version },
};

pub fn main(init: std.process.Init) u8 {
    const gpa = init.arena.allocator();
    const io = init.io;

    var out_buf: [16 * 1024]u8 = undefined;
    var out_file: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    var err_buf: [4 * 1024]u8 = undefined;
    var err_file: Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);

    const argv = init.minimal.args.toSlice(gpa) catch return 1;
    const code = run(gpa, io, init.environ_map, &out_file.interface, &err_file.interface, if (argv.len > 0) argv[1..] else argv);
    out_file.interface.flush() catch {};
    err_file.interface.flush() catch {};
    return code;
}

fn colorAllowed(io: Io, env: *const std.process.Environ.Map, file: Io.File, flag_off: bool) bool {
    if (flag_off) return false;
    if (env.get("NO_COLOR")) |v| if (v.len > 0) return false;
    if (env.get("TERM")) |t| if (std.mem.eql(u8, t, "dumb")) return false;
    return file.isTty(io) catch false;
}

fn run(
    gpa: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    out: *Io.Writer,
    err: *Io.Writer,
    argv: []const [:0]const u8,
) u8 {
    var plain: std.ArrayList([]const u8) = .empty;
    for (argv) |a| plain.append(gpa, a) catch return 1;

    var app: App = .{
        .gpa = gpa,
        .io = io,
        .env = env,
        .out = out,
        .err = err,
        .color = false,
        .err_color = colorAllowed(io, env, .stderr(), false),
        .json = false,
        .base_url = App.default_base_url,
    };
    defer app.deinit();

    var diag: args.Diagnostic = .{};
    const s = args.split(gpa, plain.items, &diag) catch |e| switch (e) {
        error.Usage => {
            _ = app.fail(.usage, "{s}. See `cadastre help`", .{diag.message}) catch {};
            return @intFromEnum(app.exit_code);
        },
        error.OutOfMemory => return 1,
    };
    app.json = s.globals.json;
    app.color = colorAllowed(io, env, .stdout(), s.globals.no_color);
    app.err_color = colorAllowed(io, env, .stderr(), s.globals.no_color);

    const raw_base = s.globals.base_url orelse app.getenv("CADASTRE_BASE_URL") orelse App.default_base_url;
    app.base_url = url.normalizeBase(raw_base) catch {
        _ = app.fail(.usage, "the base URL must be http(s)://host[:port], got \"{s}\"", .{raw_base}) catch {};
        return @intFromEnum(app.exit_code);
    };
    if (std.mem.indexOfAny(u8, app.base_url, " \t\"'\\") != null) {
        _ = app.fail(.usage, "the base URL must not contain spaces or quotes", .{}) catch {};
        return @intFromEnum(app.exit_code);
    }

    if (s.globals.version) {
        commands.version(&app, &.{}) catch {};
        return @intFromEnum(app.exit_code);
    }
    const name = s.command orelse {
        help.print(&app, null);
        return if (s.globals.help) 0 else 2;
    };
    if (std.mem.eql(u8, name, "help")) {
        help.print(&app, if (s.rest.len > 0) s.rest[0] else null);
        return @intFromEnum(app.exit_code);
    }
    for (table) |c| {
        if (!std.mem.eql(u8, c.name, name)) continue;
        if (s.globals.help) {
            help.print(&app, name);
            return 0;
        }
        c.run(&app, s.rest) catch {};
        return @intFromEnum(app.exit_code);
    }
    _ = app.fail(.usage, "unknown command \"{s}\". See `cadastre help`", .{name}) catch {};
    return @intFromEnum(app.exit_code);
}

test {
    _ = @import("url.zig");
    _ = @import("pkce.zig");
    _ = @import("args.zig");
    _ = @import("requirements.zig");
    _ = @import("store.zig");
    _ = @import("render.zig");
    _ = @import("json_value.zig");
    _ = @import("http.zig");
    _ = @import("api.zig");
    _ = @import("oauth.zig");
    _ = @import("commands.zig");
    _ = @import("mcp.zig");
    _ = @import("help.zig");
    std.testing.refAllDecls(@This());
}
