//! The commands. Each data command prints the API's answer as it came under
//! --json (attribution included), else a table with the attribution below it.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const App = @import("App.zig");
const args = @import("args.zig");
const api = @import("api.zig");
const oauth = @import("oauth.zig");
const store = @import("store.zig");
const url = @import("url.zig");
const render = @import("render.zig");
const requirements = @import("requirements.zig");
const jv = @import("json_value.zig");
const build_options = @import("build_options");

pub const Error = App.Error;

/// Turns an allocation failure into a reported error.
fn m(app: *App, v: anytype) Error!@typeInfo(@TypeOf(v)).error_union.payload {
    return v catch |err| switch (err) {
        error.OutOfMemory => app.fail(.failure, "out of memory", .{}),
        else => |e| return e,
    };
}

fn w(app: *App, result: anytype) Error!void {
    result catch return app.fail(.failure, "could not write the output", .{});
}

fn emitJson(app: *App, answer: api.Answer) Error!void {
    try w(app, app.out.writeAll(std.mem.trimEnd(u8, answer.raw, "\n")));
    try w(app, app.out.writeByte('\n'));
}

fn attribution(app: *App, answer: api.Answer) Error!void {
    try w(app, render.attribution(app.gpa, app.out, answer.root, app.base_url, app.color));
}

fn printTable(app: *App, t: *render.Table) Error!void {
    try w(app, t.print(app.out, app.color));
}

fn parse(app: *App, rest: []const []const u8, specs: []const args.Spec) Error!args.Options {
    var diag: args.Diagnostic = .{};
    return args.parse(app.gpa, rest, specs, &diag) catch |err| switch (err) {
        error.Usage => app.fail(.usage, "{s}", .{diag.message}),
        error.OutOfMemory => app.fail(.failure, "out of memory", .{}),
    };
}

fn usageError(app: *App, diag: args.Diagnostic, err: args.Error) Error {
    return switch (err) {
        error.Usage => app.fail(.usage, "{s}", .{diag.message}),
        error.OutOfMemory => app.fail(.failure, "out of memory", .{}),
    };
}

fn positiveInt(app: *App, o: args.Options, name: []const u8) Error!?[]const u8 {
    const raw = o.get(name) orelse return null;
    const n = std.fmt.parseInt(u32, raw, 10) catch 0;
    if (n == 0) return app.fail(.usage, "--{s} must be a whole number of 1 or more", .{name});
    return raw;
}

fn noPositionals(app: *App, o: args.Options, command: []const u8) Error!void {
    if (o.positionals.len > 0) return app.fail(.usage, "`cadastre {s}` takes no argument \"{s}\" (see `cadastre {s} --help`)", .{ command, o.positionals[0], command });
}

fn footerPage(app: *App, root: Value, noun: []const u8) Error!void {
    const meta = jv.get(root, "meta") orelse return;
    const total = jv.num(meta, "total") orelse return;
    const page = jv.num(meta, "page");
    const pages = jv.num(meta, "total_pages");
    if (page != null and pages != null and pages.? > 1) {
        try w(app, app.out.print("\nPage {d} of {d} ({d} {s}). Use --page to see more.\n", .{ page.?, pages.?, total, noun }));
    } else {
        try w(app, app.out.print("\n{d} {s}.\n", .{ total, if (total == 1) noun[0 .. noun.len - 1] else noun }));
    }
}

// ---- datasets ---------------------------------------------------------------------------

pub fn datasets(app: *App, rest: []const []const u8) Error!void {
    const o = try parse(app, rest, &.{});
    if (o.positionals.len > 1) return app.fail(.usage, "`cadastre datasets` takes at most one dataset key", .{});
    if (o.positionals.len == 1) return dataset(app, o.positionals[0]);

    const answer = try api.get(app, "/datasets", &.{});
    if (app.json) return emitJson(app, answer);
    return renderDatasets(app, answer);
}

pub fn renderDatasets(app: *App, answer: api.Answer) Error!void {
    var t: render.Table = .init(app.gpa, &.{
        .{ .title = "KEY" },
        .{ .title = "NAME", .max = 48 },
        .{ .title = "PUBLISHER", .max = 32 },
        .{ .title = "GEOGRAPHIES" },
        .{ .title = "VINTAGES" },
        .{ .title = "MEASURES", .alignment = .right },
    });
    const data = jv.arr(answer.root, "data");
    for (data) |d| {
        try m(app, t.add(&.{
            jv.str(d, "key") orelse "-",
            jv.str(d, "name") orelse "-",
            jv.str(d, "publisher") orelse "-",
            try m(app, render.joinList(app.gpa, jv.arr(d, "geographies"), ",")),
            try m(app, vintageRange(app.gpa, jv.arr(d, "vintages"))),
            try m(app, render.cell(app.gpa, jv.get(d, "measures_count"))),
        }));
    }
    if (data.len == 0) {
        try w(app, app.out.writeAll("No datasets are served through the API yet.\n"));
    } else {
        try printTable(app, &t);
        try w(app, app.out.print("\n{d} datasets. `cadastre datasets <key>` lists a dataset's measures.\n", .{data.len}));
    }
    try attribution(app, answer);
}

fn vintageRange(gpa: Allocator, items: []const Value) Allocator.Error![]const u8 {
    if (items.len == 0) return "-";
    var lo: f64 = std.math.inf(f64);
    var hi: f64 = -std.math.inf(f64);
    for (items) |v| if (jv.asNum(v)) |n| {
        lo = @min(lo, n);
        hi = @max(hi, n);
    };
    if (!std.math.isFinite(lo)) return "-";
    if (lo == hi) return std.fmt.allocPrint(gpa, "{d}", .{lo});
    return std.fmt.allocPrint(gpa, "{d}-{d}", .{ lo, hi });
}

fn validKey(s: []const u8, extra: u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == extra)) return false;
    return true;
}

fn dataset(app: *App, key: []const u8) Error!void {
    if (!validKey(key, '-')) return app.fail(.usage, "\"{s}\" is not a dataset key (lower-case letters, digits and -; see `cadastre datasets`)", .{key});
    const answer = try api.get(app, try m(app, std.fmt.allocPrint(app.gpa, "/datasets/{s}", .{key})), &.{});
    if (app.json) return emitJson(app, answer);
    return renderDataset(app, answer, key);
}

pub fn renderDataset(app: *App, answer: api.Answer, key: []const u8) Error!void {
    const d = jv.get(answer.root, "data");
    const out = app.out;
    try w(app, out.print("{s} ({s})\n", .{ jv.str(d, "name") orelse key, key }));
    try field(app, "Publisher", jv.str(d, "publisher"));
    try field(app, "Category", jv.str(d, "category"));
    try field(app, "License", jv.str(d, "license"));
    try field(app, "License URL", jv.str(d, "license_url"));
    try field(app, "Source", jv.str(d, "url"));
    try field(app, "Refreshed", jv.str(d, "refresh_cadence"));
    try field(app, "Vintages", try m(app, render.joinYears(app.gpa, jv.arr(d, "vintages"), ", ")));
    try field(app, "Geographies", try m(app, render.joinList(app.gpa, jv.arr(d, "geographies"), ", ")));
    try w(app, out.writeByte('\n'));
    try measureTable(app, jv.arr(d, "measures"));
    try attribution(app, answer);
}

fn field(app: *App, label: []const u8, value: ?[]const u8) Error!void {
    const v = value orelse return;
    if (v.len == 0) return;
    try w(app, app.out.print("  {s}:", .{label}));
    try w(app, app.out.splatByteAll(' ', 15 -| label.len));
    try w(app, app.out.print("{s}\n", .{v}));
}

// ---- measures ---------------------------------------------------------------------------

const geographies = [_][]const u8{ "msa", "county", "state" };

fn checkGeography(app: *App, raw: ?[]const u8) Error!void {
    const g = raw orelse return;
    for (geographies) |known| if (std.mem.eql(u8, g, known)) return;
    return app.fail(.usage, "--geography must be msa, county or state (got \"{s}\")", .{g});
}

pub fn measures(app: *App, rest: []const []const u8) Error!void {
    const o = try parse(app, rest, &.{
        .{ .name = "q", .value = true },
        .{ .name = "geography", .value = true },
        .{ .name = "dataset", .value = true },
        .{ .name = "page", .value = true },
        .{ .name = "per-page", .value = true },
    });
    if (o.positionals.len > 1) return app.fail(.usage, "`cadastre measures` takes at most one measure name", .{});
    if (o.positionals.len == 1) return measure(app, o.positionals[0]);
    try checkGeography(app, o.get("geography"));
    const answer = try api.get(app, "/measures", &.{
        .{ .name = "q", .value = o.get("q") },
        .{ .name = "geography", .value = o.get("geography") },
        .{ .name = "dataset", .value = o.get("dataset") },
        .{ .name = "page", .value = try positiveInt(app, o, "page") },
        .{ .name = "per_page", .value = try positiveInt(app, o, "per-page") },
    });
    if (app.json) return emitJson(app, answer);
    return renderMeasures(app, answer);
}

pub fn renderMeasures(app: *App, answer: api.Answer) Error!void {
    const data = jv.arr(answer.root, "data");
    if (data.len == 0) {
        try w(app, app.out.writeAll("No measures match.\n"));
    } else {
        try measureTable(app, data);
        try footerPage(app, answer.root, "measures");
        try w(app, app.out.writeAll("* computed by Cadastre at that geography (`cadastre measures <name>` says how).\n"));
    }
    try attribution(app, answer);
}

fn measureTable(app: *App, items: []const Value) Error!void {
    var t: render.Table = .init(app.gpa, &.{
        .{ .title = "NAME" },
        .{ .title = "LABEL", .max = 44 },
        .{ .title = "UNIT", .max = 24 },
        .{ .title = "DATASET" },
        .{ .title = "GEOGRAPHIES" },
    });
    for (items) |item| {
        var geos: std.ArrayList(u8) = .empty;
        if (jv.obj(item, "geographies")) |g| {
            var it = g.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try m(app, geos.append(app.gpa, ','));
                first = false;
                try m(app, geos.appendSlice(app.gpa, entry.key_ptr.*));
                if (jv.boolean(entry.value_ptr.*, "computed_by_cadastre") orelse false) try m(app, geos.append(app.gpa, '*'));
            }
        }
        try m(app, t.add(&.{
            jv.str(item, "name") orelse "-",
            jv.str(item, "label") orelse "-",
            jv.str(item, "unit") orelse "-",
            jv.str(item, "dataset") orelse "-",
            if (geos.items.len == 0) "-" else geos.items,
        }));
    }
    try printTable(app, &t);
}

fn measure(app: *App, name: []const u8) Error!void {
    if (!validKey(name, '_')) return app.fail(.usage, "\"{s}\" is not a measure name (lower-case letters, digits and _; see `cadastre measures`)", .{name});
    const answer = try api.get(app, try m(app, std.fmt.allocPrint(app.gpa, "/measures/{s}", .{name})), &.{});
    if (app.json) return emitJson(app, answer);
    return renderMeasure(app, answer, name);
}

pub fn renderMeasure(app: *App, answer: api.Answer, name: []const u8) Error!void {
    const d = jv.get(answer.root, "data");
    try w(app, app.out.print("{s} ({s})\n", .{ jv.str(d, "label") orelse name, name }));
    try field(app, "Unit", jv.str(d, "unit"));
    try field(app, "Dataset", jv.str(d, "dataset"));
    try w(app, app.out.writeByte('\n'));
    var t: render.Table = .init(app.gpa, &.{
        .{ .title = "GEOGRAPHY" },
        .{ .title = "REGIONS", .alignment = .right },
        .{ .title = "VINTAGES" },
        .{ .title = "BY CADASTRE" },
        .{ .title = "CALCULATION" },
    });
    if (jv.obj(d, "geographies")) |g| {
        var it = g.iterator();
        while (it.next()) |entry| {
            const v = entry.value_ptr.*;
            try m(app, t.add(&.{
                entry.key_ptr.*,
                try m(app, render.cell(app.gpa, jv.get(v, "regions"))),
                try m(app, render.joinYears(app.gpa, jv.arr(v, "vintages"), ", ")),
                if (jv.boolean(v, "computed_by_cadastre") orelse false) "yes" else "no",
                jv.str(v, "calculation") orelse "-",
            }));
        }
    }
    try printTable(app, &t);
    try attribution(app, answer);
}

// ---- metros -----------------------------------------------------------------------------

pub fn metros(app: *App, rest: []const []const u8) Error!void {
    const o = try parse(app, rest, &.{
        .{ .name = "state", .value = true },
        .{ .name = "q", .value = true },
        .{ .name = "page", .value = true },
        .{ .name = "per-page", .value = true },
    });
    try noPositionals(app, o, "metros");
    const answer = try api.get(app, "/metros", &.{
        .{ .name = "state", .value = o.get("state") },
        .{ .name = "q", .value = o.get("q") },
        .{ .name = "page", .value = try positiveInt(app, o, "page") },
        .{ .name = "per_page", .value = try positiveInt(app, o, "per-page") },
    });
    if (app.json) return emitJson(app, answer);
    return renderMetros(app, answer);
}

pub fn renderMetros(app: *App, answer: api.Answer) Error!void {
    const data = jv.arr(answer.root, "data");
    if (data.len == 0) {
        try w(app, app.out.writeAll("No metros match.\n"));
    } else {
        var t: render.Table = .init(app.gpa, &.{
            .{ .title = "CBSA" },
            .{ .title = "NAME", .max = 48 },
            .{ .title = "STATES" },
            .{ .title = "RTW" },
            .{ .title = "POPULATION", .alignment = .right },
        });
        for (data) |d| try m(app, t.add(&.{
            jv.str(d, "cbsa") orelse "-",
            jv.str(d, "name") orelse "-",
            try m(app, render.joinList(app.gpa, jv.arr(d, "states"), ",")),
            try m(app, render.cell(app.gpa, jv.get(d, "right_to_work"))),
            try m(app, render.cell(app.gpa, jv.get(d, "population"))),
        }));
        try printTable(app, &t);
        try footerPage(app, answer.root, "metros");
    }
    try attribution(app, answer);
}

/// A metro reference in a path: its id, CBSA code or slug, the slug's
/// slashes percent-encoded.
pub fn metroPath(gpa: Allocator, ref: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(gpa, "/metros/{s}", .{try url.encodeAlloc(gpa, ref)});
}

pub fn metro(app: *App, rest: []const []const u8) Error!void {
    const o = try parse(app, rest, &.{});
    if (o.positionals.len != 1) return app.fail(.usage, "usage: cadastre metro <cbsa|slug|id>  (e.g. cadastre metro 12420)", .{});
    const answer = try api.get(app, try m(app, metroPath(app.gpa, o.positionals[0])), &.{});
    if (app.json) return emitJson(app, answer);
    return renderMetro(app, answer, o.positionals[0]);
}

pub fn renderMetro(app: *App, answer: api.Answer, ref: []const u8) Error!void {
    const d = jv.get(answer.root, "data");
    try w(app, app.out.print("{s}\n", .{jv.str(d, "name") orelse ref}));
    try field(app, "CBSA", jv.str(d, "cbsa"));
    try field(app, "Slug", jv.str(d, "slug"));
    try field(app, "States", try m(app, render.joinList(app.gpa, jv.arr(d, "states"), ", ")));
    try field(app, "Right to work", try m(app, render.cell(app.gpa, jv.get(d, "right_to_work"))));
    if (jv.get(d, "population") != null) try field(app, "Population", try m(app, render.cell(app.gpa, jv.get(d, "population"))));
    try w(app, app.out.writeByte('\n'));
    const items = jv.arr(d, "measures");
    if (items.len == 0) {
        try w(app, app.out.writeAll("No measures served for this metro.\n"));
    } else {
        var t: render.Table = .init(app.gpa, &.{
            .{ .title = "MEASURE", .max = 44 },
            .{ .title = "VALUE", .alignment = .right },
            .{ .title = "UNIT", .max = 24 },
            .{ .title = "VINTAGE" },
            .{ .title = "DATASET" },
            .{ .title = "NAME" },
        });
        var any_computed = false;
        for (items) |item| {
            const computed = jv.boolean(item, "computed_by_cadastre") orelse false;
            any_computed = any_computed or computed;
            const vintages = jv.arr(item, "vintages");
            try m(app, t.add(&.{
                if (computed) try m(app, std.fmt.allocPrint(app.gpa, "{s} *", .{jv.str(item, "label") orelse "-"})) else jv.str(item, "label") orelse "-",
                try m(app, render.cell(app.gpa, jv.get(item, "value"))),
                jv.str(item, "unit") orelse "-",
                if (vintages.len > 0) try m(app, render.plain(app.gpa, vintages[vintages.len - 1])) else "-",
                jv.str(item, "dataset") orelse "-",
                jv.str(item, "name") orelse "-",
            }));
        }
        try printTable(app, &t);
        if (any_computed) try w(app, app.out.writeAll("\n* computed by Cadastre from the publisher's figures (--json gives the calculation).\n"));
    }
    try attribution(app, answer);
}

pub fn compare(app: *App, rest: []const []const u8) Error!void {
    const o = try parse(app, rest, &.{.{ .name = "measures", .value = true }});
    if (o.positionals.len < 1) return app.fail(.usage, "usage: cadastre compare <metro> <metro>... [--measures a,b]", .{});
    if (o.positionals.len > 25) return app.fail(.usage, "compare takes at most 25 metros", .{});
    const ids = try m(app, std.mem.join(app.gpa, ",", o.positionals));
    const answer = try api.get(app, "/metros/compare", &.{
        .{ .name = "ids", .value = ids },
        .{ .name = "measures", .value = o.get("measures") },
    });
    if (app.json) return emitJson(app, answer);
    return renderCompare(app, answer);
}

pub fn renderCompare(app: *App, answer: api.Answer) Error!void {
    const d = jv.get(answer.root, "data");
    const ms = jv.arr(d, "measures");
    const mets = jv.arr(d, "metros");
    var columns: std.ArrayList(render.Column) = .empty;
    try m(app, columns.append(app.gpa, .{ .title = "MEASURE", .max = 40 }));
    try m(app, columns.append(app.gpa, .{ .title = "UNIT", .max = 16 }));
    for (mets) |mt| try m(app, columns.append(app.gpa, .{ .title = shortName(jv.str(mt, "name") orelse "?"), .alignment = .right }));
    var t: render.Table = .init(app.gpa, columns.items);
    for (ms) |me| {
        const name = jv.str(me, "name") orelse continue;
        var row: std.ArrayList([]const u8) = .empty;
        const computed = jv.boolean(me, "computed_by_cadastre") orelse false;
        const label = jv.str(me, "label") orelse name;
        try m(app, row.append(app.gpa, if (computed) try m(app, std.fmt.allocPrint(app.gpa, "{s} *", .{label})) else label));
        try m(app, row.append(app.gpa, jv.str(me, "unit") orelse "-"));
        for (mets) |mt| try m(app, row.append(app.gpa, try m(app, render.cell(app.gpa, jv.get(jv.get(mt, "values"), name)))));
        try m(app, t.add(row.items));
    }
    try printTable(app, &t);
    try w(app, app.out.writeByte('\n'));
    for (mets) |mt| try w(app, app.out.print("  {s}  {s}\n", .{ jv.str(mt, "cbsa") orelse "-", jv.str(mt, "name") orelse "-" }));
    try w(app, app.out.writeAll("* computed by Cadastre from the publisher's figures.\n"));
    try attribution(app, answer);
}

/// "Austin-Round Rock, TX" -> "Austin-Round Rock" for a column heading.
fn shortName(name: []const u8) []const u8 {
    const comma = std.mem.lastIndexOfScalar(u8, name, ',') orelse return name;
    return name[0..comma];
}

// ---- screen and rank --------------------------------------------------------------------

fn screenInput(app: *App, o: args.Options) Error!requirements.Screen {
    var diag: args.Diagnostic = .{};
    return requirements.screenFromOptions(app.gpa, o, &diag) catch |err| usageError(app, diag, err);
}

fn limitOf(app: *App, o: args.Options, default: usize) Error!usize {
    const raw = o.get("limit") orelse return if (app.json) 0 else default;
    return std.fmt.parseInt(usize, raw, 10) catch app.fail(.usage, "--limit must be a whole number (0 for all)", .{});
}

fn funnel(app: *App, d: ?Value) Error!void {
    const stages = jv.arr(d, "funnel");
    if (stages.len == 0) return;
    var t: render.Table = .init(app.gpa, &.{ .{ .title = "FUNNEL" }, .{ .title = "METROS", .alignment = .right } });
    for (stages) |s| try m(app, t.add(&.{ jv.str(s, "label") orelse "-", try m(app, render.cell(app.gpa, jv.get(s, "count"))) }));
    try printTable(app, &t);
    try w(app, app.out.writeByte('\n'));
}

fn more(app: *App, shown: usize, total: usize) Error!void {
    if (shown < total) try w(app, app.out.print("... and {d} more (--limit 0 shows all, --json gives everything).\n", .{total - shown}));
}

pub fn screen(app: *App, rest: []const []const u8) Error!void {
    const o = try parse(app, rest, &(requirements.requirement_flags ++ [_]args.Spec{.{ .name = "limit", .value = true }}));
    try noPositionals(app, o, "screen");
    const input = try screenInput(app, o);
    const limit = try limitOf(app, o, 50);
    const body = try m(app, requirements.screenBody(app.gpa, input));
    const answer = try api.post(app, "/screen", body);
    if (app.json) return emitJson(app, answer);
    return renderScreen(app, answer, limit);
}

pub fn renderScreen(app: *App, answer: api.Answer, limit: usize) Error!void {
    const d = jv.get(answer.root, "data");
    try funnel(app, d);
    const gates = jv.arr(d, "gates");
    const mets = jv.arr(d, "metros");
    try w(app, app.out.print("{d} {s} pass{s}.\n\n", .{ mets.len, if (mets.len == 1) "metro" else "metros", if (mets.len == 1) "es" else "" }));
    if (mets.len > 0) {
        var columns: std.ArrayList(render.Column) = .empty;
        try m(app, columns.appendSlice(app.gpa, &.{ .{ .title = "CBSA" }, .{ .title = "NAME", .max = 40 }, .{ .title = "STATES" } }));
        var gate_measures: std.ArrayList([]const u8) = .empty;
        for (gates) |g| if (jv.str(g, "measure")) |name| {
            for (gate_measures.items) |seen| {
                if (std.mem.eql(u8, seen, name)) break;
            } else {
                try m(app, gate_measures.append(app.gpa, name));
                try m(app, columns.append(app.gpa, .{ .title = gateTitle(g), .alignment = .right, .max = 28 }));
            }
        };
        var t: render.Table = .init(app.gpa, columns.items);
        for (mets, 0..) |mt, i| {
            if (limit != 0 and i >= limit) break;
            var row: std.ArrayList([]const u8) = .empty;
            try m(app, row.appendSlice(app.gpa, &.{
                jv.str(mt, "cbsa") orelse "-",
                jv.str(mt, "name") orelse "-",
                try m(app, render.joinList(app.gpa, jv.arr(mt, "states"), ",")),
            }));
            for (gate_measures.items) |name| try m(app, row.append(app.gpa, try m(app, render.cell(app.gpa, jv.get(jv.get(mt, "values"), name)))));
            try m(app, t.add(row.items));
        }
        try printTable(app, &t);
        try more(app, if (limit == 0) mets.len else @min(limit, mets.len), mets.len);
    }
    try attribution(app, answer);
}

/// A gate's column heading: its measure's name (labels like "Population ≥
/// 250K" describe the gate, not the figure).
fn gateTitle(g: Value) []const u8 {
    return jv.str(g, "measure") orelse jv.str(g, "label") orelse "?";
}

pub fn rank(app: *App, rest: []const []const u8) Error!void {
    const o = try parse(app, rest, &(requirements.rank_flags ++ [_]args.Spec{.{ .name = "limit", .value = true }}));
    try noPositionals(app, o, "rank");
    const input = try screenInput(app, o);
    var diag: args.Diagnostic = .{};
    const criteria = requirements.criteriaFromOptions(app.gpa, o, &diag) catch |err| return usageError(app, diag, err);
    const limit = try limitOf(app, o, 25);
    const body = try m(app, requirements.rankBody(app.gpa, input, criteria, o.has("include-eliminated")));
    const answer = try api.post(app, "/rank", body);
    if (app.json) return emitJson(app, answer);
    return renderRank(app, answer, limit, o.has("include-eliminated"));
}

pub fn renderRank(app: *App, answer: api.Answer, limit: usize, include_eliminated: bool) Error!void {
    const d = jv.get(answer.root, "data");
    try funnel(app, d);
    const crits = jv.arr(d, "criteria");
    if (crits.len > 0) {
        var ct: render.Table = .init(app.gpa, &.{
            .{ .title = "CRITERION", .max = 40 },
            .{ .title = "MEASURE" },
            .{ .title = "DIRECTION" },
            .{ .title = "WEIGHT", .alignment = .right },
            .{ .title = "CUTOFF" },
            .{ .title = "OBSERVED", .alignment = .right },
        });
        for (crits) |c| {
            const cutoff = jv.get(c, "cutoff");
            const cut_text: []const u8 = if (jv.str(cutoff, "comparator")) |cmp|
                try m(app, std.fmt.allocPrint(app.gpa, "{s} {s}", .{ cmp, try m(app, render.cell(app.gpa, jv.get(cutoff, "value"))) }))
            else
                "-";
            try m(app, ct.add(&.{
                jv.str(c, "label") orelse "-",
                jv.str(c, "measure") orelse "-",
                jv.str(c, "direction") orelse "-",
                try m(app, render.cell(app.gpa, jv.get(c, "weight"))),
                cut_text,
                try m(app, render.cell(app.gpa, jv.get(c, "observed"))),
            }));
        }
        try printTable(app, &ct);
        try w(app, app.out.writeByte('\n'));
    }
    const mets = jv.arr(d, "metros");
    const method = jv.str(d, "method") orelse "";
    try w(app, app.out.print("{d} {s} ranked{s}{s}.\n\n", .{ mets.len, if (mets.len == 1) "metro" else "metros", if (method.len > 0) " by " else "", method }));
    if (mets.len > 0) {
        var columns: std.ArrayList(render.Column) = .empty;
        try m(app, columns.appendSlice(app.gpa, &.{
            .{ .title = "RANK", .alignment = .right },
            .{ .title = "CBSA" },
            .{ .title = "NAME", .max = 40 },
            .{ .title = "SCORE", .alignment = .right },
        }));
        for (crits) |c| try m(app, columns.append(app.gpa, .{ .title = jv.str(c, "measure") orelse "?", .alignment = .right }));
        const show_reasons = include_eliminated;
        if (show_reasons) try m(app, columns.append(app.gpa, .{ .title = "ELIMINATED" }));
        var t: render.Table = .init(app.gpa, columns.items);
        for (mets, 0..) |mt, i| {
            if (limit != 0 and i >= limit) break;
            var row: std.ArrayList([]const u8) = .empty;
            try m(app, row.appendSlice(app.gpa, &.{
                try m(app, render.cell(app.gpa, jv.get(mt, "rank"))),
                jv.str(mt, "cbsa") orelse "-",
                jv.str(mt, "name") orelse "-",
                try m(app, render.cell(app.gpa, jv.get(mt, "composite"))),
            }));
            for (crits) |c| {
                const name = jv.str(c, "measure") orelse "";
                var value: ?Value = null;
                for (jv.arr(mt, "criteria")) |mc| {
                    if (std.mem.eql(u8, jv.str(mc, "measure") orelse "", name)) value = jv.get(mc, "value");
                }
                try m(app, row.append(app.gpa, try m(app, render.cell(app.gpa, value))));
            }
            if (show_reasons) {
                const reasons = jv.arr(mt, "reasons");
                try m(app, row.append(app.gpa, if (jv.boolean(mt, "eliminated") orelse false)
                    (if (reasons.len > 0) try m(app, render.joinList(app.gpa, reasons, "; ")) else "yes")
                else
                    ""));
            }
            try m(app, t.add(row.items));
        }
        try printTable(app, &t);
        try more(app, if (limit == 0) mets.len else @min(limit, mets.len), mets.len);
    }
    try attribution(app, answer);
}

// ---- account ----------------------------------------------------------------------------

pub fn login(app: *App, rest: []const []const u8) Error!void {
    const o = try parse(app, rest, &.{
        .{ .name = "device" },
        .{ .name = "key" },
        .{ .name = "no-browser" },
        .{ .name = "client-id", .value = true },
    });
    try noPositionals(app, o, "login");
    const modes = @as(u8, @intFromBool(o.has("device"))) + @intFromBool(o.has("key"));
    if (modes > 1) return app.fail(.usage, "choose one of --device and --key", .{});
    if (app.getenv("CADASTRE_API_KEY") != null) app.note("Note: CADASTRE_API_KEY is set and takes precedence over the saved sign-in until you unset it.", .{});

    const client_id = oauth.clientId(app, o.get("client-id"));
    if (!std.mem.eql(u8, app.base_url, App.default_base_url) and std.mem.eql(u8, client_id, oauth.production_client_id) and !o.has("key")) {
        app.note("Note: signing in to {s} with getcadastre.com's client_id. If the server says the client is unknown, set CADASTRE_CLIENT_ID to the id `bin/rails oauth:cli_client` prints there.", .{app.base_url});
    }
    const backend = if (o.has("key"))
        try loginKey(app)
    else if (o.has("device"))
        try oauth.loginDevice(app, .{ .client_id = client_id })
    else
        try oauth.loginBrowser(app, .{ .client_id = client_id, .open_browser = !o.has("no-browser") });

    // Confirm with the API, as the credential will be used.
    const answer = try api.get(app, "/me", &.{});
    if (app.json) {
        const out = .{ .signed_in = true, .base_url = app.base_url, .store = backend.label(), .me = answer.root };
        try w(app, std.json.Stringify.value(out, .{}, app.out));
        try w(app, app.out.writeByte('\n'));
        return;
    }
    try w(app, app.out.print("Signed in to {s} as {s} in {s} ({s}).\n", .{
        app.base_url,
        personName(answer.root),
        jv.str(jv.get(answer.root, "account"), "name") orelse "your account",
        jv.str(jv.get(answer.root, "account"), "role") orelse "member",
    }));
    try w(app, app.out.print("Saved to the {s}{s}{s}.\n", .{ backend.label(), if (backend == .file) " " else "", if (backend == .file) try storePath(app) else "" }));
    try w(app, app.out.writeAll("\nNext: `cadastre metros`, `cadastre screen --help`, or connect an AI assistant with `cadastre mcp add claude-code`.\n"));
}

fn storePath(app: *App) Error![]const u8 {
    return store.filePath(app) catch |err| switch (err) {
        error.Reported => error.Reported,
        error.OutOfMemory => app.fail(.failure, "out of memory", .{}),
    };
}

fn personName(me: Value) []const u8 {
    const user = jv.get(me, "user");
    return jv.str(user, "name") orelse jv.str(user, "id") orelse "(unknown)";
}

/// Reads an API key from stdin (hidden when it is a terminal), checks its
/// shape and saves it. The key is never taken from argv, where shell history
/// and `ps` would keep it.
fn loginKey(app: *App) Error!store.Backend {
    const stdin = std.Io.File.stdin();
    const tty = stdin.isTty(app.io) catch false;
    if (tty) {
        try w(app, app.err.writeAll("Paste an API key from Settings > API keys (input hidden): "));
        try w(app, app.err.flush());
    }
    const echo = if (tty) disableEcho(stdin) else null;
    var buf: [1024]u8 = undefined;
    var reader = stdin.readerStreaming(app.io, &buf);
    const line = reader.interface.takeDelimiter('\n') catch null;
    if (echo) |saved| restoreEcho(stdin, saved);
    if (tty) app.note("", .{});
    const key = std.mem.trim(u8, (line orelse ""), " \r\t\n");
    if (key.len == 0) return app.fail(.usage, "no API key given. Paste it when asked, or pipe it: `pbpaste | cadastre login --key`", .{});
    if (!std.mem.startsWith(u8, key, "cad_key_")) return app.fail(.usage, "that is not a Cadastre API key (they start with cad_key_)", .{});
    return store.save(app, .{ .kind = "api_key", .api_key = try m(app, app.gpa.dupe(u8, key)) }) catch |err| switch (err) {
        error.Reported => error.Reported,
        error.OutOfMemory => app.fail(.failure, "out of memory", .{}),
    };
}

const Termios = if (builtin.os.tag == .windows) void else std.posix.termios;

fn disableEcho(file: std.Io.File) ?Termios {
    if (builtin.os.tag == .windows) return null;
    const saved = std.posix.tcgetattr(file.handle) catch return null;
    var raw = saved;
    raw.lflag.ECHO = false;
    std.posix.tcsetattr(file.handle, .NOW, raw) catch return null;
    return saved;
}

fn restoreEcho(file: std.Io.File, saved: Termios) void {
    if (builtin.os.tag == .windows) return;
    std.posix.tcsetattr(file.handle, .NOW, saved) catch {};
}

pub fn logout(app: *App, rest: []const []const u8) Error!void {
    const o = try parse(app, rest, &.{.{ .name = "revoke" }});
    try noPositionals(app, o, "logout");
    const loaded = store.load(app) catch |err| switch (err) {
        error.Reported => return error.Reported,
        error.OutOfMemory => return app.fail(.failure, "out of memory", .{}),
    };
    var revoked = false;
    if (loaded) |l| {
        const c = l.credential;
        if (c.isOauth()) {
            // Revoking the refresh token ends the whole sign-in (its access
            // tokens too); the access token is revoked as well in case there
            // is no refresh token.
            if (c.refresh_token) |t| revoked = oauth.revoke(app, t, c.client_id) catch false;
            if (c.access_token) |t| revoked = (oauth.revoke(app, t, c.client_id) catch false) or revoked;
        } else if (o.has("revoke")) {
            if (c.api_key) |k| revoked = oauth.revoke(app, k, null) catch false;
        }
        _ = store.delete(app) catch |err| switch (err) {
            error.Reported => return error.Reported,
            error.OutOfMemory => return app.fail(.failure, "out of memory", .{}),
        };
    }
    if (app.json) {
        try w(app, std.json.Stringify.value(.{ .base_url = app.base_url, .signed_out = loaded != null, .revoked = revoked }, .{}, app.out));
        try w(app, app.out.writeByte('\n'));
    } else if (loaded) |l| {
        if (l.credential.isOauth()) {
            try w(app, app.out.print("Signed out of {s}{s}.\n", .{ app.base_url, if (revoked) " and revoked the sign-in" else " (the server could not be told; disconnect it in Settings > Authorized apps)" }));
        } else if (revoked) {
            try w(app, app.out.print("Removed and revoked the API key for {s}.\n", .{app.base_url}));
        } else {
            try w(app, app.out.print("Removed the API key for {s} from this machine. The key itself still works: revoke it in Settings > API keys if it should stop (`cadastre logout --revoke` removes and revokes in one step).\n", .{app.base_url}));
        }
    } else {
        try w(app, app.out.print("Not signed in to {s}.\n", .{app.base_url}));
    }
    if (app.getenv("CADASTRE_API_KEY") != null) app.note("Note: CADASTRE_API_KEY is still set in your environment.", .{});
}

pub fn whoami(app: *App, rest: []const []const u8) Error!void {
    const o = try parse(app, rest, &.{});
    try noPositionals(app, o, "whoami");
    const cred = try api.current(app);
    const answer = try api.get(app, "/me", &.{});
    if (app.json) return emitJson(app, answer);
    const me = answer.root;
    const account = jv.get(me, "account");
    const credential = jv.get(me, "credential");
    const where: []const u8 = switch (cred.origin) {
        .env => "CADASTRE_API_KEY",
        .stored => if (cred.saved) |s| s.backend.label() else "saved",
    };
    try w(app, app.out.print("{s}\n", .{app.base_url}));
    try field(app, "User", personName(me));
    try field(app, "Account", try m(app, std.fmt.allocPrint(app.gpa, "{s} ({s})", .{ jv.str(account, "name") orelse "-", jv.str(account, "role") orelse "-" })));
    try field(app, "Credential", try m(app, std.fmt.allocPrint(app.gpa, "{s}, scopes: {s}", .{
        jv.str(credential, "type") orelse "-",
        try m(app, render.joinList(app.gpa, jv.arr(credential, "scopes"), " ")),
    })));
    try field(app, "From", where);
}

// ---- docs, version ----------------------------------------------------------------------

pub fn docs(app: *App, rest: []const []const u8) Error!void {
    const o = try parse(app, rest, &.{.{ .name = "print" }});
    if (o.positionals.len > 1) return app.fail(.usage, "usage: cadastre docs [topic]  (e.g. cadastre docs api)", .{});
    const page = if (o.positionals.len == 1) o.positionals[0] else "";
    for (page) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '/'))
        return app.fail(.usage, "\"{s}\" is not a docs page (e.g. api, mcp, rights)", .{page});
    const target = try m(app, if (page.len == 0)
        std.fmt.allocPrint(app.gpa, "{s}/docs", .{app.base_url})
    else
        std.fmt.allocPrint(app.gpa, "{s}/docs/{s}", .{ app.base_url, page }));
    if (app.json) {
        try w(app, std.json.Stringify.value(.{ .url = target }, .{}, app.out));
        try w(app, app.out.writeByte('\n'));
        return;
    }
    try w(app, app.out.print("{s}\n", .{target}));
    if (!o.has("print")) _ = oauth.openBrowser(app, target);
}

pub fn version(app: *App, rest: []const []const u8) Error!void {
    const o = try parse(app, rest, &.{});
    try noPositionals(app, o, "version");
    const target = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);
    if (app.json) {
        try w(app, std.json.Stringify.value(.{ .version = build_options.version, .target = target, .zig = builtin.zig_version_string }, .{}, app.out));
        try w(app, app.out.writeByte('\n'));
    } else {
        try w(app, app.out.print("cadastre {s} ({s}, zig {s})\n", .{ build_options.version, target, builtin.zig_version_string }));
    }
}

const testing = std.testing;

test "a metro slug's slashes are encoded in the path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("/metros/us%2Ftx%2Faustin-12420", try metroPath(arena.allocator(), "us/tx/austin-12420"));
    try testing.expectEqualStrings("/metros/12420", try metroPath(arena.allocator(), "12420"));
}

test "column headings and vintages" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try testing.expectEqualStrings("Austin-Round Rock", shortName("Austin-Round Rock, TX"));
    try testing.expectEqualStrings("Nowhere", shortName("Nowhere"));
    const v = try std.json.parseFromSliceLeaky(Value, gpa, "[2019,2023,2021]", .{});
    try testing.expectEqualStrings("2019-2023", try vintageRange(gpa, v.array.items));
    const one = try std.json.parseFromSliceLeaky(Value, gpa, "[2025]", .{});
    try testing.expectEqualStrings("2025", try vintageRange(gpa, one.array.items));
    try testing.expectEqualStrings("-", try vintageRange(gpa, &.{}));
}

/// An App writing to memory, for rendering the recorded answers.
const TestApp = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,
    app: App,

    fn init(self: *TestApp) void {
        self.arena = .init(testing.allocator);
        const gpa = self.arena.allocator();
        self.env = .init(gpa);
        self.out = .init(gpa);
        self.err = .init(gpa);
        self.app = .{
            .gpa = gpa,
            .io = testing.io,
            .env = &self.env,
            .out = &self.out.writer,
            .err = &self.err.writer,
            .color = false,
            .err_color = false,
            .json = false,
            .base_url = App.default_base_url,
        };
    }

    fn answer(self: *TestApp, name: []const u8) !api.Answer {
        const gpa = self.arena.allocator();
        const path = try std.fmt.allocPrint(gpa, "test/fixtures/{s}", .{name});
        const raw = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1 << 20));
        return .{ .raw = raw, .root = try std.json.parseFromSliceLeaky(Value, gpa, raw, .{}) };
    }

    fn expectOutput(self: *TestApp, needles: []const []const u8) !void {
        const text = self.out.written();
        for (needles) |needle| {
            if (std.mem.indexOf(u8, text, needle) == null) {
                std.debug.print("missing \"{s}\" in:\n{s}\n", .{ needle, text });
                return error.TestExpectedOutput;
            }
        }
    }

    fn deinit(self: *TestApp) void {
        self.arena.deinit();
    }
};

const credits = "Carry these credits with the figures: https://getcadastre.com/terms#api";

test "datasets: a table of the recorded answer, then its attribution" {
    var t: TestApp = undefined;
    t.init();
    defer t.deinit();
    try renderDatasets(&t.app, try t.answer("datasets.json"));
    try t.expectOutput(&.{ "KEY", "acs", "U.S. Census Bureau", "msa,county", "5 datasets", "Attribution", "Source: CDC", credits });
}

test "one dataset lists its measures" {
    var t: TestApp = undefined;
    t.init();
    defer t.deinit();
    try renderDataset(&t.app, try t.answer("dataset.json"), "acs");
    try t.expectOutput(&.{ "American Community Survey", "Vintages:", "2023", "population", "Attribution", credits });
}

test "measures and a metro's profile" {
    var t: TestApp = undefined;
    t.init();
    defer t.deinit();
    try renderMeasures(&t.app, try t.answer("measures.json"));
    try t.expectOutput(&.{ "unemployment_rate", "msa*", "7 measures" });
    try renderMetro(&t.app, try t.answer("metro.json"), "12420");
    try t.expectOutput(&.{ "Austin-Round Rock, TX", "CBSA:", "12420", "2,400,000", "Industrial electricity price *", "2025", "computed by Cadastre", credits });
    // Years are not grouped like counts.
    try testing.expect(std.mem.indexOf(u8, t.out.written(), "2,025") == null);
}

test "metros and compare" {
    var t: TestApp = undefined;
    t.init();
    defer t.deinit();
    try renderMetros(&t.app, try t.answer("metros.json"));
    try t.expectOutput(&.{ "CBSA", "46140", "Tulsa, OK", "4 metros" });
    try renderCompare(&t.app, try t.answer("compare.json"));
    try t.expectOutput(&.{ "Austin-Round Rock", "Tulsa", "Fresno", "Unemployment rate", "3.9", credits });
}

test "screen: funnel, survivors with their gate values, attribution" {
    var t: TestApp = undefined;
    t.init();
    defer t.deinit();
    try renderScreen(&t.app, try t.answer("screen.json"), 50);
    try t.expectOutput(&.{ "FUNNEL", "Population ≥ 250K", "2 metros pass", "unemployment_rate", "Austin-Round Rock, TX", "3.4", credits });
}

test "rank: criteria, ranks, composites, values; --limit" {
    var t: TestApp = undefined;
    t.init();
    defer t.deinit();
    try renderRank(&t.app, try t.answer("rank.json"), 1, false);
    try t.expectOutput(&.{ "CRITERION", "lower_better", "ranked by percentile", "Tulsa, OK", "66.7", "... and 2 more", credits });
    try testing.expect(std.mem.indexOf(u8, t.out.written(), "Fresno") == null);
}
