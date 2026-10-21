const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const runtime_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/lifecycle.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const runtime = b.addLibrary(.{
        .name = "search-runtime",
        .linkage = .static,
        .root_module = runtime_module,
    });

    const common_modules = .{
        "configuration",
        "errors",
        "allocator",
        "scheduler",
        "cancellation",
        "worker_pool",
        "lifecycle",
        "cluster_launcher",
        "deployment_worker",
        "signals",
    };
    inline for (common_modules, 0..) |name, i| {
        runtime_module.addImport(name, b.createModule(.{
            .root_source_file = b.path("src/runtime/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }

    const network_modules = .{
        "http_client",
        "http_server",
        "tls",
        "protocol",
        "serialization",
        "transport",
    };
    inline for (network_modules, 0..) |name, i| {
        runtime_module.addImport("net_" ++ name, b.createModule(.{
            .root_source_file = b.path("src/network/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }

    const crawl_modules = .{
        "frontier",
        "frontier_partition",
        "fetcher",
        "browser_runtime",
        "dom_executor",
        "html_parser",
        "document_extractor",
        "canonicalization",
        "url_normalization",
        "deduplication",
        "recrawl_scheduler",
        "domain_velocity",
        "crawl_coordinator",
        "crawl_state",
    };
    inline for (crawl_modules, 0..) |name, i| {
        runtime_module.addImport("crawl_" ++ name, b.createModule(.{
            .root_source_file = b.path("src/crawl/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }

    const ingestion_modules = .{
        "stream_engine",
        "write_ahead_log",
        "event_codec",
        "partition_router",
        "backpressure",
        "content_filter",
        "spam_classifier",
        "quality_features",
        "live_index_writer",
    };
    inline for (ingestion_modules, 0..) |name, i| {
        runtime_module.addImport("ing_" ++ name, b.createModule(.{
            .root_source_file = b.path("src/ingestion/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }

    const models_modules = .{
        "tokenizer",
        "tensor",
        "tensor_ops",
        "transformer",
        "attention",
        "dual_encoder",
        "embedding_service",
        "paragraph_predictor",
        "structural_encoder",
        "entity_classifier",
        "passage_extractor",
        "checkpoint",
        "model_registry",
        "model_version",
        "inference_client",
    };
    inline for (models_modules, 0..) |name, i| {
        runtime_module.addImport("model_" ++ name, b.createModule(.{
            .root_source_file = b.path("src/models/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }

    const training_modules = .{
        "training_runtime",
        "contrastive_loss",
        "multitask_loss",
        "optimizer",
        "temperature_scaling",
        "regularization",
        "negative_mining",
        "graph_quality",
        "curriculum",
        "checkpoint_transfer",
        "drift_detection",
        "training_coordinator",
    };
    inline for (training_modules, 0..) |name, i| {
        runtime_module.addImport("train_" ++ name, b.createModule(.{
            .root_source_file = b.path("src/training/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }

    const index_modules = .{
        "vector_index",
        "binary_quantization",
        "centroid_manager",
        "clustering",
        "shard_manager",
        "posting_lists",
        "metadata_index",
        "filter_engine",
        "deletion_manager",
        "compaction",
        "mmap_store",
        "nvme_store",
        "replication",
        "consistency",
        "snapshots",
        "recovery",
    };
    inline for (index_modules, 0..) |name, i| {
        runtime_module.addImport("index_" ++ name, b.createModule(.{
            .root_source_file = b.path("src/index/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }

    const scoring_modules = .{
        "simd_dispatch",
        "scalar_kernel",
        "x86_avx2",
        "x86_avx512",
        "arm_neon",
        "arm_sve",
        "lookup_tables",
        "binary_scoring",
        "norm_compensation",
        "numeric_stability",
        "candidate_scanner",
    };
    inline for (scoring_modules, 0..) |name, i| {
        runtime_module.addImport("score_" ++ name, b.createModule(.{
            .root_source_file = b.path("src/scoring/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }

    const retrieval_modules = .{
        "query_parser",
        "query_router",
        "sparse_index",
        "bm25",
        "dense_search",
        "cluster_probe",
        "scatter_gather",
        "candidate_merge",
        "reranker",
        "reciprocal_rank_fusion",
        "ranking_features",
        "citation_verifier",
        "candidate_heap",
    };
    inline for (retrieval_modules, 0..) |name, i| {
        runtime_module.addImport("retr_" ++ name, b.createModule(.{
            .root_source_file = b.path("src/retrieval/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }

    const orchestration_modules = .{
        "query_dag",
        "dag_scheduler",
        "deadlines",
        "speculative_execution",
        "branch_cancellation",
        "research_pipeline",
        "gpu_scheduler",
        "workload_coordinator",
        "modal_client",
    };
    inline for (orchestration_modules, 0..) |name, i| {
        runtime_module.addImport("orch_" ++ name, b.createModule(.{
            .root_source_file = b.path("src/orchestration/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }

    const highlights_modules = .{
        "paragraph_segmentation",
        "context_windows",
        "relevance_scoring",
        "highlight_extractor",
        "source_alignment",
    };
    inline for (highlights_modules, 0..) |name, i| {
        runtime_module.addImport("hl_" ++ name, b.createModule(.{
            .root_source_file = b.path("src/highlights/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }

    const cache_modules = .{
        "query_embeddings",
        "cluster_postings",
        "rendered_results",
        "cache_coordinator",
        "invalidation",
    };
    inline for (cache_modules, 0..) |name, i| {
        runtime_module.addImport("cache_" ++ name, b.createModule(.{
            .root_source_file = b.path("src/cache/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }

    const api_modules = .{
        "routes",
        "search_handler",
        "ingestion_handler",
        "research_handler",
        "highlights_handler",
        "entity_handler",
        "request_codec",
        "response_codec",
    };
    inline for (api_modules, 0..) |name, i| {
        runtime_module.addImport("api_" ++ name, b.createModule(.{
            .root_source_file = b.path("src/api/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }

    const telemetry_modules = .{
        "metrics",
        "tracing",
        "latency_histograms",
        "anomaly_detection",
        "crawler_anomalies",
        "model_drift",
        "index_health",
        "exporters",
    };
    inline for (telemetry_modules, 0..) |name, i| {
        runtime_module.addImport("tel_" ++ name, b.createModule(.{
            .root_source_file = b.path("src/telemetry/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }

    const storage_modules = .{
        "document_store",
        "metadata_store",
        "graph_store",
        "checkpoint_store",
        "transaction_log",
        "document",
    };
    inline for (storage_modules, 0..) |name, i| {
        runtime_module.addImport("store_" ++ name, b.createModule(.{
            .root_source_file = b.path("src/storage/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }

    const util_modules = .{
        "hashing",
        "checksums",
        "compression",
        "bloom_filter",
        "sketches",
        "binary_codec",
        "time",
        "platform",
    };
    inline for (util_modules, 0..) |name, i| {
        runtime_module.addImport("util_" ++ name, b.createModule(.{
            .root_source_file = b.path("src/util/" ++ name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }));
    }

    b.installArtifact(runtime);

    const gpu_module = b.createModule(.{
        .root_source_file = b.path("src/gpu_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    gpu_module.addImport("workload", b.createModule(.{
        .root_source_file = b.path("modal/workload_protocol.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    gpu_module.addImport("artifacts", b.createModule(.{
        .root_source_file = b.path("modal/model_artifacts.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    const gpu = b.addExecutable(.{
        .name = "gpu-worker",
        .root_module = gpu_module,
    });
    b.installArtifact(gpu);

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
        .{ "shard-rebalancer", "tools/shard_rebalancer.zig" },
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
        executable.root_module.linkLibrary(runtime);
        b.installArtifact(executable);
        if (index == 0) {
            const run = b.addRunArtifact(executable);
            run.step.dependOn(b.getInstallStep());
            if (b.args) |args| run.addArgs(args);
            b.step("run", "Run search node").dependOn(&run.step);
        }
    }

    const simd_flags = b.addStep(.{
        .name = "simd-kernels",
        .description = "Verify SIMD target specialization availability",
    });
    simd_flags.step.dependOn(b.getInstallStep());
}
