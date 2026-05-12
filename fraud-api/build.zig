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

    const mod = b.addModule("main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const router_mod = b.addModule("router", .{
        .root_source_file = b.path("src/router.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const payload_mod = b.addModule("payload", .{
        .root_source_file = b.path("src/payload.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const quantization_mod = b.addModule("quantization", .{
        .root_source_file = b.path("src/quantization.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const scorer_mod = b.addModule("scorer", .{
        .root_source_file = b.path("src/scorer.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const dataset_mod = b.addModule("dataset", .{
        .root_source_file = b.path("src/dataset.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const http_mod = b.addModule("http", .{
        .root_source_file = b.path("src/http.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const response_mod = b.addModule("response", .{
        .root_source_file = b.path("src/response.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/main_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "main", .module = mod },
                .{ .name = "router", .module = router_mod },
                .{ .name = "payload", .module = payload_mod },
                .{ .name = "quantization", .module = quantization_mod },
                .{ .name = "scorer", .module = scorer_mod },
                .{ .name = "dataset", .module = dataset_mod },
                .{ .name = "http", .module = http_mod },
                .{ .name = "response", .module = response_mod },
            },
        }),
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
