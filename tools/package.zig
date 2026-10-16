//! Release packaging for `zig build release`, in Zig so the build needs no
//! tar, gzip or sha256sum on the machine (they differ between macOS, Linux and
//! Windows).
//!
//!   package tar <binary> <path in archive> <out.tar.gz> <out.tar.gz.sha256>
//!   package sums <out SHA256SUMS> <file.sha256>...
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.Usage;

    const cwd = Io.Dir.cwd();
    if (std.mem.eql(u8, args[1], "tar")) {
        if (args.len != 6) return error.Usage;
        const binary = try cwd.readFileAlloc(io, args[2], arena, .limited(256 << 20));

        // The tar, in memory: one executable, mtime 0 so the archive depends
        // only on the binary.
        var tar_bytes: Io.Writer.Allocating = .init(arena);
        var tar: std.tar.Writer = .{ .underlying_writer = &tar_bytes.writer };
        try tar.writeFileBytes(args[3], binary, .{ .mode = 0o755, .mtime = 0 });
        try tar.finishPedantically();

        // gzip it. (The compressor needs room in its output's buffer.)
        var gz: Io.Writer.Allocating = try .initCapacity(arena, binary.len / 2 + 4096);
        const window = try arena.alloc(u8, std.compress.flate.max_window_len);
        const compress = try arena.create(std.compress.flate.Compress);
        compress.* = try .init(&gz.writer, window, .gzip, .default);
        try compress.writer.writeAll(tar_bytes.written());
        try compress.finish();
        const archive = gz.written();

        try cwd.writeFile(io, .{ .sub_path = args[4], .data = archive });

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(archive, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const line = try std.fmt.allocPrint(arena, "{s}  {s}\n", .{ &hex, std.fs.path.basename(args[4]) });
        try cwd.writeFile(io, .{ .sub_path = args[5], .data = line });
    } else if (std.mem.eql(u8, args[1], "sums")) {
        if (args.len < 3) return error.Usage;
        var all: Io.Writer.Allocating = .init(arena);
        for (args[3..]) |path| {
            try all.writer.writeAll(try cwd.readFileAlloc(io, path, arena, .limited(4096)));
        }
        try cwd.writeFile(io, .{ .sub_path = args[2], .data = all.written() });
    } else return error.Usage;
}
