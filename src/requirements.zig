//! The screen and rank flags, and the JSON bodies of POST /api/v1/screen and
//! POST /api/v1/rank. The Requirement keys are the API's (Api::ScreenRequest,
//! the project page's Project::Screening):
//!
//!   --min-pop 500k          requirements.tier ("250k", "500k" or "1m")
//!   --min-mfg-share 8       requirements.min_mfg_share (percent of GDP)
//!   --max-unemployment 5.5  requirements.max_unemployment (percent)
//!   --min-growth 2          requirements.min_growth (five-year population growth, percent)
//!   --max-hazard 60         requirements.max_hazard (FEMA National Risk Index)
//!   --max-power-price 10    requirements.max_elec_price (industrial, cents per kWh)
//!   --rtw-only              requirements.rtw_only
//!   --states TX,OK          scope.states
//!
//! and for rank, `--criterion measure[:weight[:higher|lower]]` and
//! `--cutoff measure:gt|gte|lt|lte:value` (repeatable) build `criteria`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");

pub const Requirements = struct {
    tier: ?[]const u8 = null,
    min_mfg_share: ?f64 = null,
    max_unemployment: ?f64 = null,
    min_growth: ?f64 = null,
    max_hazard: ?f64 = null,
    max_elec_price: ?f64 = null,
    rtw_only: ?bool = null,

    pub fn isEmpty(r: Requirements) bool {
        inline for (std.meta.fields(Requirements)) |f| {
            if (@field(r, f.name) != null) return false;
        }
        return true;
    }
};

pub const Scope = struct {
    states: []const []const u8,
};

pub const Cutoff = struct {
    comparator: []const u8,
    value: f64,
};

pub const Criterion = struct {
    measure: []const u8,
    direction: []const u8,
    weight: f64,
    cutoff: ?Cutoff = null,
};

pub const ScreenBody = struct {
    scope: ?Scope = null,
    requirements: ?Requirements = null,
};

pub const RankBody = struct {
    scope: ?Scope = null,
    requirements: ?Requirements = null,
    criteria: ?[]const Criterion = null,
    include_eliminated: ?bool = null,
};

/// The flags `screen` and `rank` share.
pub const requirement_flags = [_]args.Spec{
    .{ .name = "min-pop", .value = true },
    .{ .name = "min-mfg-share", .value = true },
    .{ .name = "max-unemployment", .value = true },
    .{ .name = "min-growth", .value = true },
    .{ .name = "max-hazard", .value = true },
    .{ .name = "max-power-price", .value = true },
    .{ .name = "max-elec-price", .value = true },
    .{ .name = "rtw-only" },
    .{ .name = "states", .value = true },
    .{ .name = "state", .value = true },
};

pub const rank_flags = requirement_flags ++ [_]args.Spec{
    .{ .name = "criterion", .value = true },
    .{ .name = "cutoff", .value = true },
    .{ .name = "include-eliminated" },
};

pub const Error = args.Error;

fn usage(diag: *args.Diagnostic, gpa: Allocator, comptime fmt: []const u8, a: anytype) Error {
    diag.message = try std.fmt.allocPrint(gpa, fmt, a);
    return error.Usage;
}

/// The population tier for `--min-pop`: the API screens on three tiers only.
pub fn parseTier(raw: []const u8) ?[]const u8 {
    var buf: [32]u8 = undefined;
    if (raw.len > buf.len) return null;
    var n: usize = 0;
    for (raw) |c| {
        if (c == ',' or c == '_' or c == ' ') continue;
        buf[n] = std.ascii.toLower(c);
        n += 1;
    }
    const s = buf[0..n];
    const tiers = [_]struct { tier: []const u8, spellings: []const []const u8 }{
        .{ .tier = "250k", .spellings = &.{ "250k", "250000", "0.25m" } },
        .{ .tier = "500k", .spellings = &.{ "500k", "500000", "0.5m" } },
        .{ .tier = "1m", .spellings = &.{ "1m", "1000k", "1000000", "1mm" } },
    };
    for (tiers) |t| {
        for (t.spellings) |sp| if (std.mem.eql(u8, s, sp)) return t.tier;
    }
    return null;
}

/// A finite number; a trailing `%` is allowed (`--min-mfg-share 8%`).
pub fn parseNumber(raw: []const u8) ?f64 {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " "), "%");
    const v = std.fmt.parseFloat(f64, trimmed) catch return null;
    if (!std.math.isFinite(v)) return null;
    return v;
}

fn numberFlag(o: args.Options, gpa: Allocator, diag: *args.Diagnostic, name: []const u8) Error!?f64 {
    const raw = o.get(name) orelse return null;
    return parseNumber(raw) orelse usage(diag, gpa, "--{s} must be a number, got \"{s}\"", .{ name, raw });
}

/// USPS codes from `TX,OK` (or `tx ok`), upper-cased and de-duplicated.
pub fn parseStates(gpa: Allocator, raw: []const u8, diag: *args.Diagnostic) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, raw, ", ");
    while (it.next()) |code| {
        if (code.len != 2 or !std.ascii.isAlphabetic(code[0]) or !std.ascii.isAlphabetic(code[1]))
            return usage(diag, gpa, "--states takes two-letter USPS codes, e.g. TX,OK (got \"{s}\")", .{code});
        const upper = try std.ascii.allocUpperString(gpa, code);
        for (out.items) |seen| {
            if (std.mem.eql(u8, seen, upper)) break;
        } else try out.append(gpa, upper);
    }
    if (out.items.len == 0) return usage(diag, gpa, "--states needs at least one state code", .{});
    return out.toOwnedSlice(gpa);
}

pub const Screen = struct {
    scope: ?Scope,
    requirements: Requirements,
};

/// The scope and Requirements from the requirement flags.
pub fn screenFromOptions(gpa: Allocator, o: args.Options, diag: *args.Diagnostic) Error!Screen {
    var r: Requirements = .{};
    if (o.get("min-pop")) |raw| {
        r.tier = parseTier(raw) orelse
            return usage(diag, gpa, "--min-pop must be 250k, 500k or 1m (the API's population tiers), got \"{s}\"", .{raw});
    }
    r.min_mfg_share = try numberFlag(o, gpa, diag, "min-mfg-share");
    r.max_unemployment = try numberFlag(o, gpa, diag, "max-unemployment");
    r.min_growth = try numberFlag(o, gpa, diag, "min-growth");
    r.max_hazard = try numberFlag(o, gpa, diag, "max-hazard");
    r.max_elec_price = try numberFlag(o, gpa, diag, "max-power-price");
    if (try numberFlag(o, gpa, diag, "max-elec-price")) |v| r.max_elec_price = v;
    if (o.has("rtw-only")) r.rtw_only = true;

    var scope: ?Scope = null;
    const states_raw = o.get("states") orelse o.get("state");
    if (states_raw) |raw| scope = .{ .states = try parseStates(gpa, raw, diag) };
    return .{ .scope = scope, .requirements = r };
}

fn parseDirection(raw: []const u8) ?[]const u8 {
    const higher = [_][]const u8{ "higher", "higher_better", "high", "max" };
    const lower = [_][]const u8{ "lower", "lower_better", "low", "min" };
    for (higher) |h| if (std.ascii.eqlIgnoreCase(raw, h)) return "higher_better";
    for (lower) |l| if (std.ascii.eqlIgnoreCase(raw, l)) return "lower_better";
    return null;
}

fn validMeasureName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

/// `measure[:weight[:higher|lower]]`; weight defaults to 1 and the direction
/// to higher_better.
pub fn parseCriterion(gpa: Allocator, raw: []const u8, diag: *args.Diagnostic) Error!Criterion {
    var parts = std.mem.splitScalar(u8, raw, ':');
    const measure = parts.next().?;
    if (!validMeasureName(measure))
        return usage(diag, gpa, "--criterion: \"{s}\" is not a measure name (lower-case letters, digits, _; see `cadastre measures`)", .{measure});
    var c: Criterion = .{ .measure = measure, .direction = "higher_better", .weight = 1 };
    if (parts.next()) |w| {
        if (w.len > 0) {
            c.weight = parseNumber(w) orelse return usage(diag, gpa, "--criterion {s}: the weight \"{s}\" is not a number", .{ raw, w });
            if (c.weight < 0) return usage(diag, gpa, "--criterion {s}: the weight must be 0 or more", .{raw});
        }
    }
    if (parts.next()) |d| {
        c.direction = parseDirection(d) orelse return usage(diag, gpa, "--criterion {s}: the direction must be higher or lower", .{raw});
    }
    if (parts.next() != null) return usage(diag, gpa, "--criterion {s}: expected measure[:weight[:higher|lower]]", .{raw});
    return c;
}

/// `measure:gt|gte|lt|lte:value`: the criterion eliminates the metros for
/// which `value comparator cutoff` holds.
pub fn parseCutoff(gpa: Allocator, raw: []const u8, diag: *args.Diagnostic) Error!struct { measure: []const u8, cutoff: Cutoff } {
    var parts = std.mem.splitScalar(u8, raw, ':');
    const measure = parts.next().?;
    const comparator = parts.next() orelse "";
    const value = parts.next() orelse "";
    if (parts.next() != null or !validMeasureName(measure))
        return usage(diag, gpa, "--cutoff {s}: expected measure:gt|gte|lt|lte:value, e.g. unemployment_rate:gt:6", .{raw});
    const comparators = [_][]const u8{ "lt", "lte", "gt", "gte" };
    const cmp = for (comparators) |k| {
        if (std.mem.eql(u8, k, comparator)) break k;
    } else return usage(diag, gpa, "--cutoff {s}: the comparator must be gt, gte, lt or lte", .{raw});
    const v = parseNumber(value) orelse return usage(diag, gpa, "--cutoff {s}: \"{s}\" is not a number", .{ raw, value });
    return .{ .measure = measure, .cutoff = .{ .comparator = cmp, .value = v } };
}

/// The rank criteria: one per --criterion, each --cutoff attached to its
/// measure's criterion (or, for a measure with no --criterion, a gate-only
/// criterion of weight 0).
pub fn criteriaFromOptions(gpa: Allocator, o: args.Options, diag: *args.Diagnostic) Error![]const Criterion {
    var list: std.ArrayList(Criterion) = .empty;
    for (try o.all(gpa, "criterion")) |raw| {
        const c = try parseCriterion(gpa, raw, diag);
        for (list.items) |seen| {
            if (std.mem.eql(u8, seen.measure, c.measure))
                return usage(diag, gpa, "--criterion {s}: a measure may be used by one criterion only", .{c.measure});
        }
        try list.append(gpa, c);
    }
    for (try o.all(gpa, "cutoff")) |raw| {
        const parsed = try parseCutoff(gpa, raw, diag);
        for (list.items) |*c| {
            if (std.mem.eql(u8, c.measure, parsed.measure)) {
                c.cutoff = parsed.cutoff;
                break;
            }
        } else try list.append(gpa, .{ .measure = parsed.measure, .direction = "higher_better", .weight = 0, .cutoff = parsed.cutoff });
    }
    if (list.items.len > 20) return usage(diag, gpa, "at most 20 criteria", .{});
    return list.toOwnedSlice(gpa);
}

const stringify_options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };

pub fn screenBody(gpa: Allocator, s: Screen) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, ScreenBody{
        .scope = s.scope,
        .requirements = if (s.requirements.isEmpty()) null else s.requirements,
    }, stringify_options);
}

pub fn rankBody(gpa: Allocator, s: Screen, criteria: []const Criterion, include_eliminated: bool) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, RankBody{
        .scope = s.scope,
        .requirements = if (s.requirements.isEmpty()) null else s.requirements,
        .criteria = if (criteria.len == 0) null else criteria,
        .include_eliminated = if (include_eliminated) true else null,
    }, stringify_options);
}

const testing = std.testing;

fn parseFlags(gpa: Allocator, argv: []const []const u8, diag: *args.Diagnostic) !args.Options {
    return args.parse(gpa, argv, &rank_flags, diag);
}

test "every requirement flag maps to the API's key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var diag: args.Diagnostic = .{};
    const o = try parseFlags(gpa, &.{
        "--min-pop",    "500k",     "--min-mfg-share", "8",  "--max-unemployment", "5.5",
        "--min-growth", "-1",       "--max-hazard",    "60", "--max-power-price",  "10",
        "--rtw-only",   "--states", "tx, ok,TX",
    }, &diag);
    const s = try screenFromOptions(gpa, o, &diag);
    const body = try screenBody(gpa, s);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, gpa, body, .{});
    const req = parsed.object.get("requirements").?.object;
    try testing.expectEqualStrings("500k", req.get("tier").?.string);
    try testing.expectEqual(@as(f64, 8), jsonNumber(req.get("min_mfg_share").?));
    try testing.expectEqual(@as(f64, 5.5), jsonNumber(req.get("max_unemployment").?));
    try testing.expectEqual(@as(f64, -1), jsonNumber(req.get("min_growth").?));
    try testing.expectEqual(@as(f64, 60), jsonNumber(req.get("max_hazard").?));
    try testing.expectEqual(@as(f64, 10), jsonNumber(req.get("max_elec_price").?));
    try testing.expect(req.get("rtw_only").?.bool);
    try testing.expectEqual(@as(usize, 7), req.count());
    const states = parsed.object.get("scope").?.object.get("states").?.array.items;
    try testing.expectEqual(@as(usize, 2), states.len);
    try testing.expectEqualStrings("TX", states[0].string);
    try testing.expectEqualStrings("OK", states[1].string);
}

fn jsonNumber(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => std.math.nan(f64),
    };
}

test "an empty screen sends an empty object" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: args.Diagnostic = .{};
    const o = try parseFlags(arena.allocator(), &.{}, &diag);
    const body = try screenBody(arena.allocator(), try screenFromOptions(arena.allocator(), o, &diag));
    try testing.expectEqualStrings("{}", body);
}

test "--max-elec-price is an alias, --state an alias of --states" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: args.Diagnostic = .{};
    const o = try parseFlags(arena.allocator(), &.{ "--max-elec-price", "9.5", "--state", "TX" }, &diag);
    const s = try screenFromOptions(arena.allocator(), o, &diag);
    try testing.expectEqual(@as(f64, 9.5), s.requirements.max_elec_price.?);
    try testing.expectEqualStrings("TX", s.scope.?.states[0]);
}

test "--min-pop accepts the three tiers in several spellings and nothing else" {
    try testing.expectEqualStrings("250k", parseTier("250K").?);
    try testing.expectEqualStrings("500k", parseTier("500,000").?);
    try testing.expectEqualStrings("1m", parseTier("1M").?);
    try testing.expectEqualStrings("1m", parseTier("1_000_000").?);
    try testing.expect(parseTier("750k") == null);
    try testing.expect(parseTier("") == null);
}

test "bad requirement values are usage errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: args.Diagnostic = .{};
    const bad = [_][]const []const u8{
        &.{ "--min-pop", "300k" },
        &.{ "--max-unemployment", "five" },
        &.{ "--max-hazard", "nan" },
        &.{ "--states", "Texas" },
        &.{ "--states", "," },
    };
    for (bad) |argv| {
        const o = try parseFlags(arena.allocator(), argv, &diag);
        try testing.expectError(error.Usage, screenFromOptions(arena.allocator(), o, &diag));
    }
    try testing.expectEqual(@as(?f64, 8), parseNumber("8%"));
}

test "criteria: weight, direction, cutoffs and gate-only cutoffs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var diag: args.Diagnostic = .{};
    const o = try parseFlags(gpa, &.{
        "--criterion",          "unemployment_rate:2:lower",
        "--criterion",          "population",
        "--cutoff",             "unemployment_rate:gt:6",
        "--cutoff",             "nri_score:gte:80",
        "--include-eliminated",
    }, &diag);
    const criteria = try criteriaFromOptions(gpa, o, &diag);
    try testing.expectEqual(@as(usize, 3), criteria.len);
    try testing.expectEqualStrings("lower_better", criteria[0].direction);
    try testing.expectEqual(@as(f64, 2), criteria[0].weight);
    try testing.expectEqualStrings("gt", criteria[0].cutoff.?.comparator);
    try testing.expectEqualStrings("higher_better", criteria[1].direction);
    try testing.expectEqual(@as(f64, 1), criteria[1].weight);
    try testing.expect(criteria[1].cutoff == null);
    try testing.expectEqualStrings("nri_score", criteria[2].measure);
    try testing.expectEqual(@as(f64, 0), criteria[2].weight);

    const body = try rankBody(gpa, try screenFromOptions(gpa, o, &diag), criteria, true);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, gpa, body, .{});
    try testing.expect(parsed.object.get("requirements") == null);
    try testing.expect(parsed.object.get("include_eliminated").?.bool);
    const first = parsed.object.get("criteria").?.array.items[0].object;
    try testing.expectEqualStrings("unemployment_rate", first.get("measure").?.string);
    try testing.expectEqual(@as(f64, 6), jsonNumber(first.get("cutoff").?.object.get("value").?));
    try testing.expect(parsed.object.get("criteria").?.array.items[1].object.get("cutoff") == null);
}

test "bad criteria are usage errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var diag: args.Diagnostic = .{};
    try testing.expectError(error.Usage, parseCriterion(gpa, "Unemployment", &diag));
    try testing.expectError(error.Usage, parseCriterion(gpa, "x:heavy", &diag));
    try testing.expectError(error.Usage, parseCriterion(gpa, "x:-1", &diag));
    try testing.expectError(error.Usage, parseCriterion(gpa, "x:1:sideways", &diag));
    try testing.expectError(error.Usage, parseCriterion(gpa, "x:1:lower:extra", &diag));
    try testing.expectError(error.Usage, parseCutoff(gpa, "x:above:6", &diag));
    try testing.expectError(error.Usage, parseCutoff(gpa, "x:gt", &diag));
    const o = try parseFlags(gpa, &.{ "--criterion", "x", "--criterion", "x:2" }, &diag);
    try testing.expectError(error.Usage, criteriaFromOptions(gpa, o, &diag));
}
