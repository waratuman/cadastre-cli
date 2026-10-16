const std = @import("std");
const zon = @import("build.zig.zon");

/// The targets `zig build release` packages. Linux builds use musl and link
/// no libc at all, so they are fully static; macOS builds link only
/// libSystem, which every Mac has.
const release_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    // The CLI.
    const exe = b.addExecutable(.{
        .name = "cadastre",
        .root_module = cliModule(b, target, optimize, options),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the CLI (zig build run -- <args>)").dependOn(&run_cmd.step);

    // Unit tests: every module under src/ is reached from main.zig's test block.
    const tests = b.addTest(.{ .root_module = cliModule(b, target, optimize, options) });
    const run_tests = b.addRunArtifact(tests);
    // The fixtures are read relative to the project root.
    run_tests.setCwd(b.path("."));
    b.step("test", "Run the unit tests").dependOn(&run_tests.step);

    // `zig build fmt`: the formatting check CI runs.
    const fmt = b.addFmt(.{ .paths = &.{ "build.zig", "build.zig.zon", "src", "tools" }, .check = true });
    b.step("fmt", "Check formatting (zig fmt --check)").dependOn(&fmt.step);

    // `zig build release`: one tarball per target (cadastre-<triple>.tar.gz,
    // holding cadastre/cadastre[.exe]) with its .sha256, plus SHA256SUMS, in
    // zig-out/release/. The names carry no version so install.sh can fetch
    // .../releases/latest/download/<name>; the version is in the binary.
    const release_step = b.step("release", "Cross-compile and package every release target into zig-out/release");
    const packager = b.addExecutable(.{
        .name = "package",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/package.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const sums = b.addRunArtifact(packager);
    sums.addArg("sums");
    const sums_file = sums.addOutputFileArg("SHA256SUMS");
    for (release_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        const triple = query.zigTriple(b.allocator) catch @panic("OOM");
        const release_exe = b.addExecutable(.{
            .name = "cadastre",
            .root_module = cliModule(b, resolved, .ReleaseSafe, options),
        });
        release_exe.root_module.strip = true;

        const archive_name = b.fmt("cadastre-{s}.tar.gz", .{triple});
        const pack = b.addRunArtifact(packager);
        pack.addArg("tar");
        pack.addArtifactArg(release_exe);
        pack.addArg(if (query.os_tag == .windows) "cadastre/cadastre.exe" else "cadastre/cadastre");
        const archive = pack.addOutputFileArg(archive_name);
        const checksum = pack.addOutputFileArg(b.fmt("{s}.sha256", .{archive_name}));
        sums.addFileArg(checksum);

        release_step.dependOn(&b.addInstallFileWithDir(archive, .{ .custom = "release" }, archive_name).step);
        release_step.dependOn(&b.addInstallFileWithDir(checksum, .{ .custom = "release" }, b.fmt("{s}.sha256", .{archive_name})).step);
    }
    release_step.dependOn(&b.addInstallFileWithDir(sums_file, .{ .custom = "release" }, "SHA256SUMS").step);
}

fn cliModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("build_options", options);
    return module;
}
