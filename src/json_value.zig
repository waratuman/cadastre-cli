//! Reading the API's answers as std.json.Value. Data answers are read
//! dynamically rather than into fixed structs, so a field the API adds later
//! (it is beta) never breaks an older CLI; a missing field reads as null.
const std = @import("std");
const Value = std.json.Value;

pub fn get(v: ?Value, key: []const u8) ?Value {
    const val = v orelse return null;
    return switch (val) {
        .object => |o| o.get(key),
        else => null,
    };
}

/// A path of keys, `path(v, &.{"data", "metros"})`.
pub fn path(v: ?Value, keys: []const []const u8) ?Value {
    var cur = v;
    for (keys) |k| cur = get(cur, k);
    return cur;
}

pub fn str(v: ?Value, key: []const u8) ?[]const u8 {
    return asStr(get(v, key));
}

pub fn asStr(v: ?Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        .number_string => |s| s,
        else => null,
    };
}

pub fn num(v: ?Value, key: []const u8) ?f64 {
    return asNum(get(v, key));
}

pub fn asNum(v: ?Value) ?f64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

pub fn boolean(v: ?Value, key: []const u8) ?bool {
    const val = get(v, key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

pub fn arr(v: ?Value, key: []const u8) []const Value {
    return asArr(get(v, key));
}

pub fn asArr(v: ?Value) []const Value {
    const val = v orelse return &.{};
    return switch (val) {
        .array => |a| a.items,
        else => &.{},
    };
}

pub fn obj(v: ?Value, key: []const u8) ?std.json.ObjectMap {
    const val = get(v, key) orelse return null;
    return switch (val) {
        .object => |o| o,
        else => null,
    };
}

const testing = std.testing;

test "missing and mistyped fields read as null" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\{"a":{"b":[1,2.5,"x"],"n":null,"t":true,"s":"y"}}
    , .{});
    try testing.expectEqual(@as(usize, 3), arr(get(v, "a"), "b").len);
    try testing.expectEqual(@as(?f64, 2.5), asNum(arr(get(v, "a"), "b")[1]));
    try testing.expect(str(get(v, "a"), "n") == null);
    try testing.expect(num(get(v, "a"), "s") == null);
    try testing.expectEqual(@as(?bool, true), boolean(get(v, "a"), "t"));
    try testing.expectEqualStrings("y", asStr(path(v, &.{ "a", "s" })).?);
    try testing.expect(path(v, &.{ "a", "zz", "q" }) == null);
    try testing.expectEqual(@as(usize, 0), arr(v, "nope").len);
}
