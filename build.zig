const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const workload = b.addModule("workload", .{ .root_source_file = b.path("modal/workload_protocol.zig"), .target = target, .optimize = optimize });
    const artifacts = b.addModule("artifacts", .{ .root_source_file = b.path("modal/model_artifacts.zig"), .target = target, .optimize = optimize });
    artifacts.addImport("workload", workload);
    const deployment = b.addModule("deployment", .{ .root_source_file = b.path("deploy/configuration.zig"), .target = target, .optimize = optimize });
    const runtime_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .link_libc = true,
    });
    runtime_module.addImport("workload", workload);
    runtime_module.addImport("artifacts", artifacts);
    runtime_module.addImport("deployment", deployment);
    const runtime = b.addLibrary(.{
        .name = "search-runtime",
        .linkage = .static,
        .root_module = runtime_module,
    });
    b.installArtifact(runtime);
    const gpu_module = b.createModule(.{ .root_source_file = b.path("src/gpu_main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    gpu_module.addImport("workload", workload);
    gpu_module.addImport("artifacts", artifacts);
    const gpu = b.addExecutable(.{ .name = "gpu-worker", .root_module = gpu_module });
    b.installArtifact(gpu);
    b.installDirectory(.{ .source_dir = b.path("modal"), .install_dir = .prefix, .install_subdir = "share/search-runtime/modal" });
    b.installDirectory(.{ .source_dir = b.path("deploy"), .install_dir = .prefix, .install_subdir = "share/search-runtime/deploy" });
    b.installDirectory(.{ .source_dir = b.path("settings"), .install_dir = .prefix, .install_subdir = "share/search-runtime/settings" });
    b.installDirectory(.{ .source_dir = b.path("schemas"), .install_dir = .prefix, .install_subdir = "share/search-runtime/schemas" });
    const programs = .{
        .{ "search-node", "src/main.zig" },
        .{ "corpus-ingestor", "tools/corpus_ingestor.zig" },
        .{ "index-builder", "tools/index_builder.zig" },
        .{ "snapshot-manager", "tools/snapshot_manager.zig" },
        .{ "crawl-worker", "tools/corpus_crawler.zig" },
        .{ "embedding-client", "tools/embedding_client.zig" },
        .{ "training-coordinator", "tools/training_coordinator.zig" },
        .{ "checkpoint-manager", "tools/checkpoint_manager.zig" },
        .{ "cluster-launcher", "tools/cluster_launcher.zig" },
        .{ "deployment-launcher", "deploy/launch.zig" },
        .{ "deployment-worker", "tools/deployment_worker.zig" },
    };
    inline for (programs, 0..) |program, index| {
        const executable = b.addExecutable(.{
            .name = program[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(program[1]),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        executable.root_module.addImport("runtime", runtime_module);
        executable.root_module.addImport("workload", workload);
        executable.root_module.addImport("artifacts", artifacts);
        executable.root_module.addImport("deployment", deployment);
        b.installArtifact(executable);
        if (index == 0) {
            const run = b.addRunArtifact(executable);
            run.step.dependOn(b.getInstallStep());
            if (b.args) |args| run.addArgs(args);
            b.step("run", "Run search node").dependOn(&run.step);
        }
    }
}
