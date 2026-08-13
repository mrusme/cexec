const std = @import("std");

const manifest = @import("build.zig.zon");

const release_targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .musleabihf },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
    .{ .cpu_arch = .aarch64, .os_tag = .windows },
    .{ .cpu_arch = .x86_64, .os_tag = .freebsd },
    .{ .cpu_arch = .aarch64, .os_tag = .freebsd },
    .{ .cpu_arch = .x86_64, .os_tag = .netbsd },
    .{ .cpu_arch = .aarch64, .os_tag = .netbsd },
    .{ .cpu_arch = .x86_64, .os_tag = .openbsd },
    .{ .cpu_arch = .aarch64, .os_tag = .openbsd },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", manifest.version);

    const cexec = b.addModule("cexec", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "cexec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cexec", .module = cexec },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run cexec").dependOn(&run.step);

    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cexec })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);

    const release_step = b.step("release", "Cross compile for every supported target");
    for (release_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        const triple = query.zigTriple(b.allocator) catch @panic("OOM");

        const release_exe = b.addExecutable(.{
            .name = "cexec",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved,
                .optimize = .ReleaseSafe,
                .imports = &.{
                    .{ .name = "cexec", .module = b.createModule(.{
                        .root_source_file = b.path("src/root.zig"),
                        .target = resolved,
                        .optimize = .ReleaseSafe,
                    }) },
                    .{ .name = "build_options", .module = options.createModule() },
                },
            }),
        });

        const install = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("release/{s}", .{triple}) } },
        });
        release_step.dependOn(&install.step);
    }
}
