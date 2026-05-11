const std = @import("std");

pub fn build(b: *std.Build) void {
    const query = std.Target.Query.parse(.{ .arch_os_abi = "x86_64-linux-musl" }) catch @panic("bad target");
    const target = b.resolveTargetQuery(query);
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "fraud_api",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&b.addRunArtifact(exe).step);
}
