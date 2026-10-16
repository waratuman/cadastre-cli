//! Command-line parsing in two passes: the global flags (allowed anywhere
//! before `--`) and the command name, then each command's own flags against
//! the list it declares. `--name value` and `--name=value` are both accepted.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Globals = struct {
    base_url: ?[]const u8 = null,
    json: bool = false,
    no_color: bool = false,
    help: bool = false,
    version: bool = false,
};

pub const Split = struct {
    globals: Globals,
    command: ?[]const u8,
    /// Everything after the command except the global flags, in order.
    rest: []const []const u8,
};

/// What went wrong, for the usage error message.
pub const Diagnostic = struct {
    message: []const u8 = "",
};

pub const Error = error{Usage} || Allocator.Error;

fn usage(diag: *Diagnostic, gpa: Allocator, comptime fmt: []const u8, args: anytype) Error {
    diag.message = try std.fmt.allocPrint(gpa, fmt, args);
    return error.Usage;
}

/// Splits argv (without the program name) into the global flags, the
/// command, and the command's arguments.
pub fn split(gpa: Allocator, argv: []const []const u8, diag: *Diagnostic) Error!Split {
    var globals: Globals = .{};
    var command: ?[]const u8 = null;
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var passthrough = false;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (passthrough) {
            try rest.append(gpa, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            passthrough = true;
            if (command != null) try rest.append(gpa, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--json")) {
            globals.json = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            globals.no_color = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            globals.help = true;
        } else if (command == null and (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version"))) {
            globals.version = true;
        } else if (std.mem.eql(u8, arg, "--base-url")) {
            i += 1;
            if (i >= argv.len) return usage(diag, gpa, "--base-url needs a value, e.g. --base-url http://127.0.0.1:3000", .{});
            globals.base_url = argv[i];
        } else if (std.mem.startsWith(u8, arg, "--base-url=")) {
            globals.base_url = arg["--base-url=".len..];
        } else if (command == null) {
            if (std.mem.startsWith(u8, arg, "-")) return usage(diag, gpa, "unknown flag {s} before the command", .{arg});
            command = arg;
        } else {
            try rest.append(gpa, arg);
        }
    }
    return .{ .globals = globals, .command = command, .rest = try rest.toOwnedSlice(gpa) };
}

/// One flag a command accepts.
pub const Spec = struct {
    name: []const u8,
    /// Takes a value (`--state TX`), else it is a switch.
    value: bool = false,
};

pub const Flag = struct { name: []const u8, value: ?[]const u8 };

pub const Options = struct {
    positionals: []const []const u8,
    flags: []const Flag,

    /// The last value given for `name`.
    pub fn get(o: Options, name: []const u8) ?[]const u8 {
        var found: ?[]const u8 = null;
        for (o.flags) |f| {
            if (std.mem.eql(u8, f.name, name)) found = f.value;
        }
        return found;
    }

    pub fn has(o: Options, name: []const u8) bool {
        for (o.flags) |f| {
            if (std.mem.eql(u8, f.name, name)) return true;
        }
        return false;
    }

    /// Every value given for a repeatable flag, in order.
    pub fn all(o: Options, gpa: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (o.flags) |f| {
            if (std.mem.eql(u8, f.name, name)) {
                if (f.value) |v| try out.append(gpa, v);
            }
        }
        return out.toOwnedSlice(gpa);
    }
};

/// Parses a command's arguments against the flags it accepts. Values may start
/// with a dash (`--min-growth -1`) because the flag says it takes one.
pub fn parse(gpa: Allocator, rest: []const []const u8, specs: []const Spec, diag: *Diagnostic) Error!Options {
    var positionals: std.ArrayList([]const u8) = .empty;
    var flags: std.ArrayList(Flag) = .empty;
    var i: usize = 0;
    var only_positionals = false;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (only_positionals or !std.mem.startsWith(u8, arg, "-") or arg.len == 1) {
            try positionals.append(gpa, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            only_positionals = true;
            continue;
        }
        if (!std.mem.startsWith(u8, arg, "--")) return usage(diag, gpa, "unknown flag {s} (flags are spelled --name)", .{arg});
        const body = arg[2..];
        const eq = std.mem.indexOfScalar(u8, body, '=');
        const name = if (eq) |e| body[0..e] else body;
        const spec = for (specs) |s| {
            if (std.mem.eql(u8, s.name, name)) break s;
        } else return usage(diag, gpa, "unknown flag --{s}", .{name});
        if (spec.value) {
            if (eq) |e| {
                try flags.append(gpa, .{ .name = spec.name, .value = body[e + 1 ..] });
            } else {
                i += 1;
                if (i >= rest.len) return usage(diag, gpa, "--{s} needs a value", .{name});
                try flags.append(gpa, .{ .name = spec.name, .value = rest[i] });
            }
        } else {
            if (eq) |e| {
                const v = body[e + 1 ..];
                if (std.mem.eql(u8, v, "false")) continue;
                if (!std.mem.eql(u8, v, "true")) return usage(diag, gpa, "--{s} is a switch: use it alone (or =true/=false)", .{name});
            }
            try flags.append(gpa, .{ .name = spec.name, .value = null });
        }
    }
    return .{ .positionals = try positionals.toOwnedSlice(gpa), .flags = try flags.toOwnedSlice(gpa) };
}

const testing = std.testing;

test "split takes the global flags from anywhere" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const s = try split(arena.allocator(), &.{ "--base-url", "http://127.0.0.1:3000", "metros", "--state", "TX", "--json", "--no-color" }, &diag);
    try testing.expectEqualStrings("metros", s.command.?);
    try testing.expectEqualStrings("http://127.0.0.1:3000", s.globals.base_url.?);
    try testing.expect(s.globals.json and s.globals.no_color and !s.globals.help);
    try testing.expectEqual(@as(usize, 2), s.rest.len);
    try testing.expectEqualStrings("--state", s.rest[0]);

    const eq = try split(arena.allocator(), &.{ "whoami", "--base-url=http://localhost:3000" }, &diag);
    try testing.expectEqualStrings("http://localhost:3000", eq.globals.base_url.?);
    try testing.expectEqual(@as(usize, 0), eq.rest.len);
}

test "split reports a missing --base-url value and an unknown leading flag" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.Usage, split(arena.allocator(), &.{ "metros", "--base-url" }, &diag));
    try testing.expectError(error.Usage, split(arena.allocator(), &.{ "--frobnicate", "metros" }, &diag));
    try testing.expectEqualStrings("unknown flag --frobnicate before the command", diag.message);
}

test "split: -h anywhere asks for help, --version only before the command" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const s = try split(arena.allocator(), &.{ "screen", "-h" }, &diag);
    try testing.expect(s.globals.help);
    const v = try split(arena.allocator(), &.{"--version"}, &diag);
    try testing.expect(v.globals.version and v.command == null);
}

test "parse reads switches, values, repeats and negative numbers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const specs = [_]Spec{
        .{ .name = "min-growth", .value = true },
        .{ .name = "criterion", .value = true },
        .{ .name = "rtw-only" },
    };
    const o = try parse(arena.allocator(), &.{ "a", "--min-growth", "-1.5", "--criterion=x:2", "--criterion", "y:1:lower", "--rtw-only", "b" }, &specs, &diag);
    try testing.expectEqual(@as(usize, 2), o.positionals.len);
    try testing.expectEqualStrings("-1.5", o.get("min-growth").?);
    try testing.expect(o.has("rtw-only"));
    const crits = try o.all(arena.allocator(), "criterion");
    try testing.expectEqual(@as(usize, 2), crits.len);
    try testing.expectEqualStrings("y:1:lower", crits[1]);
}

test "parse refuses unknown flags, missing values and valued switches" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const specs = [_]Spec{ .{ .name = "state", .value = true }, .{ .name = "rtw-only" } };
    try testing.expectError(error.Usage, parse(arena.allocator(), &.{"--nope"}, &specs, &diag));
    try testing.expectEqualStrings("unknown flag --nope", diag.message);
    try testing.expectError(error.Usage, parse(arena.allocator(), &.{"--state"}, &specs, &diag));
    try testing.expectError(error.Usage, parse(arena.allocator(), &.{"--rtw-only=yes"}, &specs, &diag));
    try testing.expectError(error.Usage, parse(arena.allocator(), &.{"-x"}, &specs, &diag));
    const off = try parse(arena.allocator(), &.{ "--rtw-only=false", "--", "--state" }, &specs, &diag);
    try testing.expect(!off.has("rtw-only"));
    try testing.expectEqualStrings("--state", off.positionals[0]);
}
