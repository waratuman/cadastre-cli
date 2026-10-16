//! Human output: aligned tables, numbers people can read, and the
//! attribution every data answer carries, printed below the figures (the
//! Terms, /terms#api, require the credits to travel with the data).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;
const jv = @import("json_value.zig");

pub const Align = enum { left, right };

pub const Column = struct {
    title: []const u8,
    alignment: Align = .left,
    /// Cells longer than this many code points are cut (0: never).
    max: usize = 0,
};

pub const Table = struct {
    gpa: Allocator,
    columns: []const Column,
    rows: std.ArrayList([]const []const u8) = .empty,

    pub fn init(gpa: Allocator, columns: []const Column) Table {
        return .{ .gpa = gpa, .columns = columns };
    }

    pub fn add(t: *Table, cells: []const []const u8) Allocator.Error!void {
        std.debug.assert(cells.len == t.columns.len);
        const row = try t.gpa.dupe([]const u8, cells);
        for (row, t.columns) |*text, col| text.* = try clip(t.gpa, text.*, col.max);
        try t.rows.append(t.gpa, row);
    }

    pub fn print(t: *Table, w: *Writer, color: bool) Writer.Error!void {
        const widths = t.gpa.alloc(usize, t.columns.len) catch return error.WriteFailed;
        for (t.columns, 0..) |c, i| widths[i] = displayWidth(c.title);
        for (t.rows.items) |row| {
            for (row, 0..) |cell_text, i| widths[i] = @max(widths[i], displayWidth(cell_text));
        }
        if (color) try w.writeAll("\x1b[1m");
        for (t.columns, 0..) |c, i| try cellOut(w, c.title, widths[i], c.alignment, i + 1 == t.columns.len);
        if (color) try w.writeAll("\x1b[0m");
        try w.writeByte('\n');
        for (t.rows.items) |row| {
            for (row, 0..) |cell_text, i| try cellOut(w, cell_text, widths[i], t.columns[i].alignment, i + 1 == t.columns.len);
            try w.writeByte('\n');
        }
    }
};

fn cellOut(w: *Writer, text: []const u8, width: usize, alignment: Align, last: bool) Writer.Error!void {
    const pad = width -| displayWidth(text);
    if (alignment == .right) try w.splatByteAll(' ', pad);
    try w.writeAll(text);
    if (alignment == .left and !last) try w.splatByteAll(' ', pad);
    if (!last) try w.writeAll("  ");
}

/// Cuts a cell to `max` code points, the last an ellipsis (keeping UTF-8
/// whole); 0 means no limit.
fn clip(gpa: Allocator, s: []const u8, max: usize) Allocator.Error![]const u8 {
    if (max == 0 or displayWidth(s) <= max) return s;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    var n: usize = 0;
    while (n + 1 < max) : (n += 1) _ = it.nextCodepointSlice();
    return std.fmt.allocPrint(gpa, "{s}…", .{std.mem.trimEnd(u8, s[0..it.i], " ")});
}

/// Code points, which is the width for the text the API returns (names,
/// labels, ≥ and ¢); not East Asian wide characters.
pub fn displayWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// 2400000 -> "2,400,000", 3.9 -> "3.9", 55.534 -> "55.53", 0.01234 -> "0.0123".
pub fn number(gpa: Allocator, v: f64) Allocator.Error![]u8 {
    if (!std.math.isFinite(v)) return gpa.dupe(u8, "-");
    const decimals: usize = if (@abs(v) >= 1 or v == 0) 2 else 4;
    var buf: [64]u8 = undefined;
    const raw = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ v, decimals }) catch return gpa.dupe(u8, "?");
    // Trim the zeros (and a bare point) after the decimal point.
    var s: []const u8 = raw;
    if (std.mem.indexOfScalar(u8, s, '.') != null) {
        s = std.mem.trimEnd(u8, s, "0");
        s = std.mem.trimEnd(u8, s, ".");
    }
    if (std.mem.eql(u8, s, "-0")) s = "0";
    // Thousands separators in the integer part.
    const neg = s.len > 0 and s[0] == '-';
    const digits_start: usize = if (neg) 1 else 0;
    const point = std.mem.indexOfScalar(u8, s, '.') orelse s.len;
    const int_part = s[digits_start..point];
    var out: std.ArrayList(u8) = .empty;
    if (neg) try out.append(gpa, '-');
    for (int_part, 0..) |c, i| {
        if (i > 0 and (int_part.len - i) % 3 == 0) try out.append(gpa, ',');
        try out.append(gpa, c);
    }
    try out.appendSlice(gpa, s[point..]);
    return out.toOwnedSlice(gpa);
}

/// A year or code: the number with no grouping ("2023").
pub fn plain(gpa: Allocator, v: ?Value) Allocator.Error![]const u8 {
    if (jv.asNum(v)) |n| {
        if (@floor(n) == n and @abs(n) < 1e15) return std.fmt.allocPrint(gpa, "{d}", .{@as(i64, @intFromFloat(n))});
    }
    return cell(gpa, v);
}

/// Joins a JSON array of years with `sep`.
pub fn joinYears(gpa: Allocator, items: []const Value, sep: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |item, i| {
        if (i > 0) try out.appendSlice(gpa, sep);
        try out.appendSlice(gpa, try plain(gpa, item));
    }
    return out.toOwnedSlice(gpa);
}

/// A JSON number (or null) as a cell.
pub fn cell(gpa: Allocator, v: ?Value) Allocator.Error![]const u8 {
    if (jv.asNum(v)) |n| return number(gpa, n);
    if (jv.asStr(v)) |s| return s;
    if (v) |val| switch (val) {
        .bool => |b| return if (b) "yes" else "no",
        else => {},
    };
    return "-";
}

/// "2026-10-16T14:11:23Z" -> "2026-10-16".
pub fn date(s: []const u8) []const u8 {
    return if (s.len >= 10 and s[4] == '-' and s[7] == '-') s[0..10] else s;
}

/// Joins a JSON array of strings (or numbers) with `sep`.
pub fn joinList(gpa: Allocator, items: []const Value, sep: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |item, i| {
        if (i > 0) try out.appendSlice(gpa, sep);
        try out.appendSlice(gpa, try cell(gpa, item));
    }
    return out.toOwnedSlice(gpa);
}

fn dim(w: *Writer, color: bool, text: []const u8) Writer.Error!void {
    if (color) try w.print("\x1b[2m{s}\x1b[0m", .{text}) else try w.writeAll(text);
}

fn bold(w: *Writer, color: bool, text: []const u8) Writer.Error!void {
    if (color) try w.print("\x1b[1m{s}\x1b[0m", .{text}) else try w.writeAll(text);
}

/// The attribution of an answer, below its figures. Prints every credit,
/// licence, link, note, disclaimer, condition and share-alike offer the API
/// sent, and when each dataset was retrieved.
pub fn attribution(gpa: Allocator, w: *Writer, root: Value, base_url: []const u8, color: bool) Writer.Error!void {
    const entries = jv.arr(root, "attribution");
    if (entries.len == 0) return;
    try w.writeByte('\n');
    try bold(w, color, "Attribution");
    try w.writeByte('\n');
    for (entries) |e| {
        const credit = jv.str(e, "credit") orelse jv.str(e, "publisher") orelse jv.str(e, "dataset") orelse "(no credit given)";
        try w.print("  {s}", .{credit});
        var meta: std.ArrayList(u8) = .empty;
        if (jv.str(e, "dataset")) |d| meta.appendSlice(gpa, d) catch return error.WriteFailed;
        if (jv.str(e, "retrieved_at")) |r| {
            if (meta.items.len > 0) meta.appendSlice(gpa, ", ") catch return error.WriteFailed;
            meta.appendSlice(gpa, "retrieved ") catch return error.WriteFailed;
            meta.appendSlice(gpa, date(r)) catch return error.WriteFailed;
        }
        if (meta.items.len > 0) {
            try w.writeByte(' ');
            try dim(w, color, "(");
            try dim(w, color, meta.items);
            try dim(w, color, ")");
        }
        try w.writeByte('\n');
        if (jv.str(e, "license")) |l| {
            try w.print("    License: {s}", .{l});
            if (jv.str(e, "license_url")) |u| try w.print(" <{s}>", .{u});
            try w.writeByte('\n');
        }
        if (jv.str(e, "url")) |u| try w.print("    {s}\n", .{u});
        for (jv.arr(e, "notes")) |n| if (jv.asStr(n)) |s| try w.print("    {s}\n", .{s});
        if (jv.str(e, "disclaimer")) |d| try w.print("    {s}\n", .{d});
        for (jv.arr(e, "conditions")) |c| if (jv.asStr(c)) |s| try w.print("    Condition: {s}\n", .{s});
        if (jv.get(e, "share_alike")) |sa| {
            if (jv.asStr(sa)) |s| try w.print("    {s}\n", .{s}) else {
                try w.writeAll("    ");
                try std.json.Stringify.value(sa, .{}, w);
                try w.writeByte('\n');
            }
        }
    }
    try dim(w, color, "  Carry these credits with the figures: ");
    try dim(w, color, base_url);
    try dim(w, color, "/terms#api\n");
}

const testing = std.testing;

test "numbers are grouped and trimmed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const cases = [_]struct { f64, []const u8 }{
        .{ 2400000, "2,400,000" },
        .{ 3.9, "3.9" },
        .{ 55.534, "55.53" },
        .{ 0, "0" },
        .{ -1234.5, "-1,234.5" },
        .{ 0.012345, "0.0123" },
        .{ 100, "100" },
        .{ 999.999, "1,000" },
        .{ -0.0001, "-0.0001" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try number(gpa, c[0]));
}

test "a table pads to the widest cell and right-aligns numbers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    var t: Table = .init(arena.allocator(), &.{ .{ .title = "METRO" }, .{ .title = "POP", .alignment = .right } });
    try t.add(&.{ "Austin-Round Rock, TX", "2,400,000" });
    try t.add(&.{ "Tulsa, OK", "1,000,000" });
    try t.print(&out.writer, false);
    try testing.expectEqualStrings(
        \\METRO                        POP
        \\Austin-Round Rock, TX  2,400,000
        \\Tulsa, OK              1,000,000
        \\
    , out.written());
}

test "long cells are clipped to the column's limit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    var t: Table = .init(arena.allocator(), &.{ .{ .title = "A", .max = 4 }, .{ .title = "B" } });
    try t.add(&.{ "≥ 250K people", "x" });
    try t.print(&out.writer, false);
    try testing.expectEqualStrings("A     B\n≥ 2…  x\n", out.written());
}

test "attribution prints every credit, note, condition and retrieval date" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const fixture = try std.Io.Dir.cwd().readFileAlloc(testing.io, "test/fixtures/metro.json", gpa, .limited(1 << 20));
    const root = try std.json.parseFromSliceLeaky(Value, gpa, fixture, .{});
    var out: std.Io.Writer.Allocating = .init(gpa);
    try attribution(gpa, &out.writer, root, "https://getcadastre.com", false);
    const text = out.written();
    for (jv.arr(root, "attribution")) |e| {
        try testing.expect(std.mem.indexOf(u8, text, jv.str(e, "credit").?) != null);
        for (jv.arr(e, "notes")) |n| try testing.expect(std.mem.indexOf(u8, text, n.string) != null);
        for (jv.arr(e, "conditions")) |c| try testing.expect(std.mem.indexOf(u8, text, c.string) != null);
        if (jv.str(e, "disclaimer")) |d| try testing.expect(std.mem.indexOf(u8, text, d) != null);
        if (jv.str(e, "retrieved_at")) |r| try testing.expect(std.mem.indexOf(u8, text, date(r)) != null);
    }
    try testing.expect(std.mem.indexOf(u8, text, "https://getcadastre.com/terms#api") != null);
}

test "no attribution array prints nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    const root = try std.json.parseFromSliceLeaky(Value, arena.allocator(), "{\"data\":[]}", .{});
    try attribution(arena.allocator(), &out.writer, root, "x", false);
    try testing.expectEqualStrings("", out.written());
}
