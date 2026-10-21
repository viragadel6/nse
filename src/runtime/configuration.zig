const std = @import("std");
const platform = @import("../util/platform.zig");
const protocol = @import("workload");

pub const ConfigurationError = error{
    InvalidRange,
    MissingField,
    IncompatibleComponents,
    InvalidPath,
    InvalidEndpoint,
    FileUnreadable,
    MalformedConfiguration,
};

pub const RuntimeConfig = struct {
    node_id: []const u8 = "node-0",
    cluster_name: []const u8 = "search-cluster",
    data_dir: []const u8 = "data",
    log_dir: []const u8 = "data/logs",
    role: []const u8 = "search",
    worker_threads: u16 = 4,
    interactive_threads: u16 = 2,
    background_threads: u16 = 2,
    queue_capacity: u32 = 4096,
    memory_budget_bytes: u64 = 4294967296,
    index_memory_bytes: u64 = 2147483648,
    cache_memory_bytes: u64 = 536870912,
    numa_aware: bool = false,
    cpu_affinity: bool = false,
    huge_pages: bool = false,
    shutdown_timeout_ms: u32 = 30000,
    startup_timeout_ms: u32 = 60000,
    connection_timeout_ms: u32 = 5000,
    recovery_enabled: bool = true,
    deterministic_ids: bool = true,
};

pub const CrawlerConfig = struct {
    user_agent: []const u8 = "distributed-search-engine/1.0",
    from_address: []const u8 = "crawler@example.invalid",
    max_redirects: u8 = 5,
    request_timeout_ms: u32 = 10000,
    connect_timeout_ms: u32 = 3000,
    idle_timeout_ms: u32 = 15000,
    sockets_per_host: u16 = 4,
    max_connections: u32 = 512,
    politeness_delay_ms: u32 = 1000,
    max_response_bytes: u32 = 8388608,
    max_links_per_page: u32 = 512,
    frontier_partitions: u32 = 64,
    frontier_capacity_urls: u64 = 1400000000000,
    bloom_expected_items: u64 = 1000000000,
    bloom_false_positive_rate: f64 = 0.01,
    fetch_retry_attempts: u32 = 3,
    fetch_retry_base_ms: u64 = 200,
    fetch_retry_max_ms: u64 = 5000,
    recrawl_min_interval_ms: u64 = 3600000,
    recrawl_max_interval_ms: u64 = 2592000000,
    velocity_window_ms: u64 = 604800000,
    domain_velocity_weight: f64 = 0.65,
    freshness_weight: f64 = 0.25,
    change_probability_floor: f64 = 0.01,
    browser_enabled: bool = false,
    browser_command: []const u8 = "chromium",
    browser_arguments: [4][]const u8 = .{ "--headless", "--disable-gpu", "--no-sandbox", "--remote-debugging-port=9222" },
    browser_argument_count: u8 = 4,
    browser_timeout_ms: u32 = 8000,
    browser_max_pages: u32 = 64,
    dom_executor_enabled: bool = true,
    dom_executor_max_nodes: u32 = 20000,
    dom_executor_max_steps: u32 = 200000,
    honor_denied_access: bool = true,
    challenge_as_failure: bool = true,
};

pub const IngestionConfig = struct {
    stream_partitions: u32 = 32,
    segment_target_bytes: u64 = 268435456,
    wal_flush_interval_ms: u32 = 250,
    wal_max_bytes: u64 = 1073741824,
    batch_max_events: u32 = 1024,
    batch_max_bytes: u64 = 8388608,
    queue_capacity: u32 = 8192,
    backpressure_high_water: f64 = 0.85,
    backpressure_low_water: f64 = 0.55,
    publication_interval_s: u32 = 3600,
    priority_publication_interval_s: u32 = 60,
    embedding_batch_size: u32 = 256,
    embedding_queue_capacity: u32 = 4096,
    spam_threshold: f64 = 0.35,
    quality_threshold: f64 = 0.25,
    duplicate_similarity_threshold: f64 = 0.9,
    shingle_count: u32 = 84,
    min_document_bytes: u32 = 256,
    max_document_bytes: u32 = 4194304,
    idempotency_window_events: u64 = 1000000,
    compaction_interval_s: u32 = 900,
    quarantine_enabled: bool = true,
    quarantine_sample_rate: f64 = 0.05,
};

pub const ModelConfig = struct {
    primary_dim: u32 = 4096,
    retained_dim: u32 = 256,
    packed_bytes: u32 = 32,
    matryoshka_dims: [4]u32 = .{ 256, 512, 1024, 4096 },
    matryoshka_count: u8 = 4,
    layers: u16 = 24,
    attention_heads: u16 = 32,
    head_dim: u16 = 128,
    feedforward_dim: u32 = 16384,
    vocabulary_size: u32 = 128256,
    max_sequence_len: u32 = 8192,
    document_max_tokens: u32 = 2048,
    query_max_tokens: u32 = 128,
    pooling: []const u8 = "mean",
    activation: []const u8 = "gelu",
    normalization_epsilon: f64 = 1e-5,
    dropout_rate: f64 = 0.0,
    checkpoint_dir: []const u8 = "data/models",
    checkpoint_format_version: u32 = 4,
    model_id: []const u8 = "dual-encoder-v1",
    workload_endpoint: []const u8 = "http://127.0.0.1:8000",
    workload_timeout_ms: u32 = 30000,
    health_endpoint: []const u8 = "http://127.0.0.1:8000/health",
    embedding_endpoint: []const u8 = "http://127.0.0.1:8000/embed",
    model_version: u64 = 1,
    response_bytes: u32 = 67108864,
    tokenizer_path: []const u8 = "data/models/tokenizer.bin",
    dtype: []const u8 = "bf16",
    quantize_binary: bool = true,
    normalization_before_quantization: bool = true,
    zero_coordinate_sign: u8 = 1,
    stochastic_dithering: bool = false,
    dithering_seed: u64 = 0x9E3779B97F4A7C15,
    temperature: f64 = 0.05,
    temperature_min: f64 = 0.01,
    temperature_max: f64 = 0.2,
};

pub const TrainingStageConfig = struct {
    name: []const u8 = "web-link-prediction",
    kind: []const u8 = "link",
    epochs: u32 = 1,
    max_steps: u64 = 100000,
    learning_rate: f64 = 1e-4,
    warmup_steps: u64 = 2000,
    batch_size: u32 = 8192,
    gradient_accumulation: u32 = 4,
    weight_decay: f64 = 0.01,
    hard_negative_count: u32 = 4,
    hard_negative_refresh_steps: u64 = 2000,
    validation_interval_steps: u64 = 5000,
    early_stop_patience: u32 = 5,
    min_improvement: f64 = 1e-4,
    enabled: bool = true,
};

pub const TrainingConfig = struct {
    seed: u64 = 20261021,
    optimizer: []const u8 = "adamw",
    beta1: f64 = 0.9,
    beta2: f64 = 0.98,
    epsilon: f64 = 1e-8,
    gradient_clip_norm: f64 = 1.0,
    mixed_precision: bool = true,
    loss_mix: []const u8 = "multitask",
    contrastive_weight: f64 = 1.0,
    canonical_url_weight: f64 = 0.15,
    entity_weight: f64 = 0.1,
    passage_weight: f64 = 0.25,
    paragraph_weight: f64 = 0.2,
    link_prediction_weight: f64 = 0.3,
    distillation_weight: f64 = 0.0,
    decoupled_contrastive: bool = false,
    margin_mse_weight: f64 = 0.0,
    variance_regularization: f64 = 0.01,
    covariance_regularization: f64 = 0.005,
    decorrelation_penalty: f64 = 0.002,
    anti_collapse_weight: f64 = 0.01,
    hubness_mitigation: bool = true,
    hubness_threshold: f64 = 4.0,
    checkpoint_interval_steps: u64 = 5000,
    checkpoint_keep: u32 = 5,
    checkpoint_dir: []const u8 = "data/models",
    resume_from_checkpoint: []const u8 = "",
    distributed_backend: []const u8 = "modal",
    gradient_sync_interval: u32 = 1,
    shard_aware_sampling: bool = true,
    hardware_profile: []const u8 = "modal-b300",
    accelerator_type: []const u8 = "b300",
    accelerator_count_per_node: u32 = 8,
    node_count: u32 = 1,
    h200_reference_node_count: u32 = 144,
    h200_reference_batch_size: u32 = 8192,
    memory_budget_gb_per_accelerator: f64 = 180.0,
    staleness_threshold: f64 = 0.15,
    negative_pool_capacity: u64 = 1000000,
    negative_refresh_interval_s: u32 = 600,
    drift_detection_interval_s: u32 = 3600,
    drift_threshold: f64 = 0.12,
    aggregator_penalty: f64 = 0.35,
    scraper_penalty: f64 = 0.4,
    authority_bonus: f64 = 0.25,
    curriculum_stages: [8]TrainingStageConfig = .{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} },
    stage_count: u8 = 8,

pub fn applyTrainingDefaults(self: TrainingConfig, request: *protocol.TrainingRequest, supplied: std.json.Value) !void {
    if (supplied != .object) return ConfigurationError.MalformedConfiguration;
    const object = supplied.object;
    const profile = HardwareProfile.fromConfig(&self);
    const stage = if (self.stage_count > 0) self.curriculum_stages[0] else TrainingStageConfig{};
    if (!object.contains("steps")) {
        var total: u64 = 0;
        var cursor: u8 = 0;
        while (cursor < self.stage_count and cursor < self.curriculum_stages.len) : (cursor += 1) {
            if (!self.curriculum_stages[cursor].enabled) continue;
            total += @min(self.curriculum_stages[cursor].max_steps, @as(u64, 1000000));
        }
        request.steps = @intCast(@max(1, @min(total, std.math.maxInt(u32))));
    }
    if (!object.contains("batch_size")) {
        const scaled = profile.scaledBatchSize(stage.batch_size);
        request.batch_size = @intCast(@max(2, @min(scaled, std.math.maxInt(u16))));
    }
    if (!object.contains("learning_rate")) {
        request.learning_rate = @floatCast(@max(1e-7, stage.learning_rate));
    }
    if (!object.contains("weight_decay")) {
        request.weight_decay = @floatCast(@max(0.0, stage.weight_decay));
    }
    if (!object.contains("gradient_clip")) {
        request.gradient_clip = @floatCast(@max(1e-6, self.gradient_clip_norm));
    }
    if (!object.contains("warmup_steps")) {
        request.warmup_steps = @intCast(@max(1, @min(stage.warmup_steps, std.math.maxInt(u32))));
    }
    if (!object.contains("checkpoint_interval")) {
        request.checkpoint_interval = @intCast(@max(1, @min(self.checkpoint_interval_steps, std.math.maxInt(u32))));
    }
    if (!object.contains("seed")) {
        request.seed = self.seed;
    }
    if (!object.contains("deadline_ms")) {
        request.deadline_ms = 86400000;
    }
    if (!object.contains("resume")) {
        request.@"resume" = self.resume_from_checkpoint.len > 0;
    }
    try protocol.validateTraining(request.*);
}
};

pub const VectorIndexConfig = struct {
    dimensions: u32 = 4096,
    retained_dimensions: u32 = 256,
    packed_vector_bytes: u32 = 32,
    centroid_count: u32 = 100000,
    shard_count: u32 = 16,
    replication_factor: u32 = 2,
    segment_max_documents: u64 = 8388608,
    segment_max_bytes: u64 = 8589934592,
    records_per_block: u32 = 64,
    block_alignment: u32 = 64,
    default_probe_count: u16 = 32,
    min_probe_count: u16 = 4,
    max_probe_count: u16 = 2048,
    centroid_recenter_interval_s: u32 = 3600,
    centroid_recenter_sample_rate: f64 = 0.02,
    clustering_iterations: u32 = 12,
    clustering_seed: u64 = 0x2545F4914F6CDD1D,
    split_occupancy_threshold: f64 = 4.0,
    merge_occupancy_threshold: f64 = 0.05,
    replication_mode: []const u8 = "leader",
    consistency_mode: []const u8 = "generation-bounded",
    compaction_min_segments: u32 = 4,
    compaction_max_segments: u32 = 16,
    tombstone_ratio_threshold: f64 = 0.25,
    snapshot_interval_s: u32 = 3600,
    index_dir: []const u8 = "data/index",
    generation_file: []const u8 = "data/index/generation",
    fallback_shard_fraction: f64 = 0.25,
    recall_target: f64 = 0.95,
    filter_cardinality_threshold: u64 = 100000,
    posting_block_size: u32 = 256,
};

pub const ScoringConfig = struct {
    subvector_width: u32 = 4,
    max_subvector_width: u32 = 8,
    lookup_table_entries: u32 = 16,
    register_resident_max_entries: u32 = 16,
    norm_compensation: bool = true,
    norm_compensation_alpha: f64 = 0.35,
    norm_compensation_beta: f64 = 0.15,
    compensated_accumulation: bool = true,
    tie_break_by_document_id: bool = true,
    quantization_zero_sign: u8 = 1,
    dithering_enabled: bool = false,
    dithering_seed: u64 = 0x9E3779B97F4A7C15,
    kernel_preference: []const u8 = "auto",
    scan_block_size: u32 = 256,
    prefetch_distance: u32 = 512,
    prefer_popcount_vector: bool = true,
    force_scalar: bool = false,
    score_scale: f64 = 1000.0,
};

pub const RankingConfig = struct {
    bm25_k1: f64 = 1.2,
    bm25_b: f64 = 0.65,
    title_field_weight: f64 = 3.0,
    heading_field_weight: f64 = 2.0,
    body_field_weight: f64 = 1.0,
    url_field_weight: f64 = 1.5,
    anchor_field_weight: f64 = 2.5,
    metadata_field_weight: f64 = 1.2,
    phrase_match_bonus: f64 = 0.35,
    exact_match_bonus: f64 = 0.5,
    default_candidate_count: u32 = 500,
    expanded_candidate_count: u32 = 5000,
    fusion_rank_constant: f64 = 60.0,
    fusion_sparse_weight: f64 = 1.0,
    fusion_dense_weight: f64 = 1.15,
    fusion_vertical_weight: f64 = 1.05,
    lexical_normalization: []const u8 = "minmax",
    semantic_normalization: []const u8 = "zscore",
    rerank_enabled: bool = true,
    rerank_candidate_count: u32 = 200,
    rerank_max_tokens: u32 = 512,
    rerank_batch_size: u32 = 32,
    rerank_precision: []const u8 = "fp8",
    rerank_attention: []const u8 = "flashattention2",
    rerank_cache_confidence: f64 = 0.9,
    freshness_half_life_days: f64 = 180.0,
    source_quality_weight: f64 = 0.35,
    originality_weight: f64 = 0.25,
    graph_quality_weight: f64 = 0.2,
    corroboration_weight: f64 = 0.2,
    default_mode: []const u8 = "hybrid",
    enable_speculative_decoding: bool = true,
};

pub const OrchestrationConfig = struct {
    default_deadline_ms: u32 = 100,
    expanded_deadline_ms: u32 = 400,
    research_deadline_ms: u32 = 600000,
    branch_deadline_fraction: f64 = 0.6,
    speculative_execution: bool = true,
    speculative_max_branches: u8 = 2,
    max_parallel_branches: u8 = 8,
    gpu_queue_capacity: u32 = 1024,
    gpu_batch_max: u32 = 64,
    gpu_batch_timeout_ms: u32 = 2,
    gpu_interactive_share: f64 = 0.7,
    gpu_max_wait_ms: u32 = 20,
    research_max_subqueries: u32 = 12,
    research_max_rounds: u32 = 4,
    research_evidence_per_subquery: u32 = 8,
    research_checkpoint_interval_ms: u32 = 10000,
    dag_node_capacity: u32 = 64,
    cancellation_check_interval_ms: u32 = 1,
    trace_sample_rate: f64 = 0.01,
    partial_results_on_timeout: bool = true,
    interactive_reserved_threads: u16 = 2,
};

pub const CacheConfig = struct {
    query_embedding_capacity: u32 = 262144,
    query_embedding_ttl_ms: u64 = 3600000,
    cluster_posting_capacity_bytes: u64 = 2147483648,
    cluster_posting_ttl_ms: u64 = 600000,
    rendered_response_capacity: u32 = 65536,
    rendered_response_ttl_ms: u64 = 60000,
    coalesce_concurrent_requests: bool = true,
    coalesce_max_waiters: u32 = 256,
    eviction_policy: []const u8 = "lru",
    generation_aware: bool = true,
    invalidate_on_model_change: bool = true,
    invalidate_on_index_generation_change: bool = true,
    shards: u32 = 64,
    stats_interval_ms: u32 = 10000,
    negative_cache_enabled: bool = true,
    negative_cache_ttl_ms: u64 = 5000,
};

pub const StorageConfig = struct {
    document_dir: []const u8 = "data/documents",
    metadata_dir: []const u8 = "data/metadata",
    graph_dir: []const u8 = "data/graph",
    checkpoint_dir: []const u8 = "data/checkpoints",
    transaction_log_dir: []const u8 = "data/txlog",
    segment_target_bytes: u64 = 1073741824,
    write_buffer_bytes: u64 = 67108864,
    compression_enabled: bool = true,
    compression_level: u8 = 1,
    sync_on_write: bool = false,
    retention_days: u32 = 180,
    max_open_segments: u32 = 64,
    bloom_bits_per_key: f64 = 10.0,
    verify_checksums_on_read: bool = true,
    recovery_verify: bool = true,
};

pub const DistributedConfig = struct {
    local_address: []const u8 = "127.0.0.1",
    local_port: u16 = 7100,
    peer_addresses: [8][]const u8 = .{ "", "", "", "", "", "", "", "" },
    peer_count: u8 = 0,
    gossip_interval_ms: u32 = 1000,
    failure_timeout_ms: u32 = 10000,
    heartbeat_interval_ms: u32 = 500,
    request_timeout_ms: u32 = 50,
    scatter_timeout_ms: u32 = 45,
    max_inflight_requests: u32 = 512,
    connection_pool_per_peer: u16 = 8,
    replication_ack_mode: []const u8 = "quorum",
    write_quorum: u8 = 2,
    read_quorum: u8 = 1,
    protocol_version: u32 = 3,
    message_max_bytes: u32 = 16777216,
    compression_enabled: bool = true,
    tls_enabled: bool = false,
    tls_backend: []const u8 = "none",
    tls_certificate_path: []const u8 = "",
    tls_private_key_path: []const u8 = "",
    rebalance_interval_s: u32 = 600,
    rebalance_skew_threshold: f64 = 0.2,
};

pub const TelemetryConfig = struct {
    collection_interval_ms: u32 = 5000,
    histogram_buckets: [8]f64 = .{ 1.0, 5.0, 10.0, 25.0, 50.0, 100.0, 250.0, 1000.0 },
    histogram_bucket_count: u8 = 8,
    export_interval_ms: u32 = 15000,
    export_format: []const u8 = "json",
    exporter_path: []const u8 = "data/telemetry",
    buffer_events: u32 = 65536,
    trace_sample_rate: f64 = 0.01,
    anomaly_window_size: u32 = 128,
    anomaly_threshold: f64 = 4.0,
    anomaly_min_samples: u32 = 32,
    crawler_anomaly_enabled: bool = true,
    model_drift_enabled: bool = true,
    index_health_enabled: bool = true,
    change_point_sensitivity: f64 = 0.05,
    retention_hours: u32 = 168,
    async_export: bool = true,
    drop_on_export_failure: bool = true,
};

pub const ApiConfig = struct {
    bind_address: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    max_request_bytes: u32 = 1048576,
    max_response_bytes: u32 = 8388608,
    request_timeout_ms: u32 = 5000,
    keep_alive_timeout_ms: u32 = 15000,
    max_connections: u32 = 4096,
    max_concurrent_requests: u32 = 2048,
    default_result_count: u32 = 10,
    max_result_count: u32 = 100,
    default_deadline_ms: u32 = 100,
    max_deadline_ms: u32 = 30000,
    enable_highlights: bool = true,
    enable_entities: bool = true,
    enable_research: bool = true,
    default_highlight_count: u32 = 3,
    max_highlight_count: u32 = 10,
    entity_categories: [8][]const u8 = .{ "organization", "person", "product", "technology", "funding_event", "research_publication", "date", "location" },
    entity_category_count: u8 = 8,
    shutdown_drain_ms: u32 = 5000,
    health_dependency_timeout_ms: u32 = 1000,
    metrics_include_histograms: bool = true,
};

pub const Config = struct {
    runtime: RuntimeConfig = .{},
    crawler: CrawlerConfig = .{},
    ingestion: IngestionConfig = .{},
    model: ModelConfig = .{},
    training: TrainingConfig = .{},
    vector_index: VectorIndexConfig = .{},
    scoring: ScoringConfig = .{},
    ranking: RankingConfig = .{},
    orchestration: OrchestrationConfig = .{},
    cache: CacheConfig = .{},
    storage: StorageConfig = .{},
    distributed: DistributedConfig = .{},
    telemetry: TelemetryConfig = .{},
    api: ApiConfig = .{},
};

pub fn defaults() Config {
    return .{};
}

fn readOptional(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ dir, name }) catch return null;
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    if (stat.size > 4 * 1024 * 1024) return null;
    return file.readToEndAlloc(allocator, 4 * 1024 * 1024) catch null;
}

fn parseInto(comptime T: type, allocator: std.mem.Allocator, dir: []const u8, name: []const u8, target: *T) !void {
    @setEvalBranchQuota(400000);
    const content = readOptional(allocator, dir, name) orelse return;
    defer allocator.free(content);
    const terminated = try allocator.dupeZ(u8, content);
    defer allocator.free(terminated);
    const parsed = std.zon.parse.fromSlice(T, allocator, terminated, null, .{}) catch |err| {
        std.debug.print("configuration: failed to parse {s}: {}\n", .{ name, err });
        return ConfigurationError.MalformedConfiguration;
    };
    target.* = parsed;
}

pub fn load(allocator: std.mem.Allocator, dir: []const u8) !Config {
    var config = defaults();
    try parseInto(RuntimeConfig, allocator, dir, "runtime.zon", &config.runtime);
    try parseInto(CrawlerConfig, allocator, dir, "crawler.zon", &config.crawler);
    try parseInto(IngestionConfig, allocator, dir, "ingestion.zon", &config.ingestion);
    try parseInto(ModelConfig, allocator, dir, "model.zon", &config.model);
    try parseInto(TrainingConfig, allocator, dir, "training.zon", &config.training);
    try parseInto(VectorIndexConfig, allocator, dir, "vector_index.zon", &config.vector_index);
    try parseInto(ScoringConfig, allocator, dir, "scoring.zon", &config.scoring);
    try parseInto(RankingConfig, allocator, dir, "ranking.zon", &config.ranking);
    try parseInto(OrchestrationConfig, allocator, dir, "orchestration.zon", &config.orchestration);
    try parseInto(CacheConfig, allocator, dir, "cache.zon", &config.cache);
    try parseInto(StorageConfig, allocator, dir, "storage.zon", &config.storage);
    try parseInto(DistributedConfig, allocator, dir, "distributed.zon", &config.distributed);
    try parseInto(TelemetryConfig, allocator, dir, "telemetry.zon", &config.telemetry);
    try parseInto(ApiConfig, allocator, dir, "api.zon", &config.api);
    try validate(config);
    return config;
}

pub fn free(allocator: std.mem.Allocator, config: *Config) void {
    std.zon.parse.free(allocator, config.runtime);
    std.zon.parse.free(allocator, config.crawler);
    std.zon.parse.free(allocator, config.ingestion);
    std.zon.parse.free(allocator, config.model);
    std.zon.parse.free(allocator, config.training);
    std.zon.parse.free(allocator, config.vector_index);
    std.zon.parse.free(allocator, config.scoring);
    std.zon.parse.free(allocator, config.ranking);
    std.zon.parse.free(allocator, config.orchestration);
    std.zon.parse.free(allocator, config.cache);
    std.zon.parse.free(allocator, config.storage);
    std.zon.parse.free(allocator, config.distributed);
    std.zon.parse.free(allocator, config.telemetry);
    std.zon.parse.free(allocator, config.api);
}

fn require(condition: bool, comptime field_name: []const u8) ConfigurationError!void {
    if (!condition) {
        std.debug.print("configuration: invalid value for {s}\n", .{field_name});
        return ConfigurationError.InvalidRange;
    }
}

pub fn validate(config: Config) ConfigurationError!void {
    try require(config.runtime.worker_threads > 0, "runtime.worker_threads");
    try require(config.runtime.interactive_threads > 0, "runtime.interactive_threads");
    try require(config.runtime.background_threads > 0, "runtime.background_threads");
    try require(config.runtime.queue_capacity > 0, "runtime.queue_capacity");
    try require(config.runtime.memory_budget_bytes >= 64 * 1024 * 1024, "runtime.memory_budget_bytes");
    try require(config.runtime.shutdown_timeout_ms > 0, "runtime.shutdown_timeout_ms");

    try require(config.crawler.max_redirects <= 10, "crawler.max_redirects");
    try require(config.crawler.request_timeout_ms > 0, "crawler.request_timeout_ms");
    try require(config.crawler.max_response_bytes > 0, "crawler.max_response_bytes");
    try require(config.crawler.frontier_partitions > 0, "crawler.frontier_partitions");
    try require(config.crawler.frontier_capacity_urls >= 1_000_000_000_000, "crawler.frontier_capacity_urls");
    try require(config.crawler.bloom_false_positive_rate > 0.0 and config.crawler.bloom_false_positive_rate < 0.5, "crawler.bloom_false_positive_rate");
    try require(config.crawler.recrawl_min_interval_ms > 0, "crawler.recrawl_min_interval_ms");
    try require(config.crawler.recrawl_max_interval_ms >= config.crawler.recrawl_min_interval_ms, "crawler.recrawl_max_interval_ms");
    try require(config.crawler.browser_argument_count <= 4, "crawler.browser_argument_count");

    try require(config.ingestion.stream_partitions > 0, "ingestion.stream_partitions");
    try require(config.ingestion.segment_target_bytes >= 1024 * 1024, "ingestion.segment_target_bytes");
    try require(config.ingestion.backpressure_high_water > config.ingestion.backpressure_low_water, "ingestion.backpressure_high_water");
    try require(config.ingestion.publication_interval_s > 0, "ingestion.publication_interval_s");
    try require(config.ingestion.embedding_batch_size > 0, "ingestion.embedding_batch_size");
    try require(config.ingestion.spam_threshold >= 0.0 and config.ingestion.spam_threshold <= 1.0, "ingestion.spam_threshold");
    try require(config.ingestion.duplicate_similarity_threshold >= 0.0 and config.ingestion.duplicate_similarity_threshold <= 1.0, "ingestion.duplicate_similarity_threshold");

    try require(config.model.primary_dim == 4096, "model.primary_dim");
    try require(config.model.retained_dim == 256, "model.retained_dim");
    try require(config.model.packed_bytes * 8 == config.model.retained_dim, "model.packed_bytes");
    try require(config.model.matryoshka_count <= 4, "model.matryoshka_count");
    try require(config.model.layers > 0 and config.model.attention_heads > 0, "model.layers");
    try require(config.model.head_dim * config.model.attention_heads == config.model.primary_dim or config.model.head_dim * config.model.attention_heads <= config.model.primary_dim, "model.head_dim");
    try require(config.model.temperature >= config.model.temperature_min and config.model.temperature <= config.model.temperature_max, "model.temperature");
    try require(config.model.document_max_tokens > 0 and config.model.query_max_tokens > 0, "model.max_tokens");

    try require(config.training.stage_count <= 8, "training.stage_count");
    try require(config.training.beta1 > 0.0 and config.training.beta2 > 0.0, "training.beta");
    try require(config.training.gradient_clip_norm > 0.0, "training.gradient_clip_norm");
    try require(config.training.checkpoint_interval_steps > 0, "training.checkpoint_interval_steps");
    try require(config.training.node_count > 0, "training.node_count");
    try require(config.training.accelerator_count_per_node > 0, "training.accelerator_count_per_node");
    try require(config.training.hardware_profile.len > 0, "training.hardware_profile");

    try require(config.vector_index.centroid_count == 100000, "vector_index.centroid_count");
    try require(config.vector_index.retained_dimensions == 256, "vector_index.retained_dimensions");
    try require(config.vector_index.packed_vector_bytes == 32, "vector_index.packed_vector_bytes");
    try require(config.vector_index.shard_count > 0, "vector_index.shard_count");
    try require(config.vector_index.replication_factor >= 1, "vector_index.replication_factor");
    try require(config.vector_index.min_probe_count <= config.vector_index.default_probe_count, "vector_index.min_probe_count");
    try require(config.vector_index.default_probe_count <= config.vector_index.max_probe_count, "vector_index.default_probe_count");
    try require(config.vector_index.block_alignment % 8 == 0, "vector_index.block_alignment");
    try require(config.vector_index.recall_target > 0.0 and config.vector_index.recall_target <= 1.0, "vector_index.recall_target");

    try require(config.scoring.subvector_width >= 1 and config.scoring.subvector_width <= config.scoring.max_subvector_width, "scoring.subvector_width");
    try require(config.scoring.lookup_table_entries == @as(u32, 1) << @as(u5, @intCast(config.scoring.subvector_width)), "scoring.lookup_table_entries");
    try require(config.scoring.scan_block_size > 0, "scoring.scan_block_size");

    try require(config.ranking.bm25_k1 > 0.0, "ranking.bm25_k1");
    try require(config.ranking.bm25_b >= 0.0 and config.ranking.bm25_b <= 1.0, "ranking.bm25_b");
    try require(config.ranking.default_candidate_count > 0, "ranking.default_candidate_count");
    try require(config.ranking.expanded_candidate_count >= config.ranking.default_candidate_count, "ranking.expanded_candidate_count");
    try require(config.ranking.fusion_rank_constant > 0.0, "ranking.fusion_rank_constant");
    try require(config.ranking.rerank_candidate_count > 0, "ranking.rerank_candidate_count");

    try require(config.orchestration.default_deadline_ms > 0, "orchestration.default_deadline_ms");
    try require(config.orchestration.expanded_deadline_ms >= config.orchestration.default_deadline_ms, "orchestration.expanded_deadline_ms");
    try require(config.orchestration.branch_deadline_fraction > 0.0 and config.orchestration.branch_deadline_fraction <= 1.0, "orchestration.branch_deadline_fraction");
    try require(config.orchestration.gpu_queue_capacity > 0, "orchestration.gpu_queue_capacity");
    try require(config.orchestration.research_max_subqueries > 0, "orchestration.research_max_subqueries");

    try require(config.cache.query_embedding_capacity > 0, "cache.query_embedding_capacity");
    try require(config.cache.cluster_posting_capacity_bytes > 0, "cache.cluster_posting_capacity_bytes");
    try require(config.cache.rendered_response_capacity > 0, "cache.rendered_response_capacity");
    try require(config.cache.shards > 0, "cache.shards");

    try require(config.storage.segment_target_bytes > 0, "storage.segment_target_bytes");
    try require(config.storage.write_buffer_bytes > 0, "storage.write_buffer_bytes");
    try require(config.storage.retention_days > 0, "storage.retention_days");

    try require(config.distributed.peer_count <= 8, "distributed.peer_count");
    try require(config.distributed.local_port > 0, "distributed.local_port");
    try require(config.distributed.request_timeout_ms > 0, "distributed.request_timeout_ms");
    try require(config.distributed.write_quorum >= 1, "distributed.write_quorum");
    try require(config.distributed.message_max_bytes > 0, "distributed.message_max_bytes");

    try require(config.telemetry.collection_interval_ms > 0, "telemetry.collection_interval_ms");
    try require(config.telemetry.histogram_bucket_count <= 8, "telemetry.histogram_bucket_count");
    try require(config.telemetry.anomaly_window_size >= 8, "telemetry.anomaly_window_size");
    try require(config.telemetry.retention_hours > 0, "telemetry.retention_hours");

    try require(config.api.port > 0, "api.port");
    try require(config.api.max_request_bytes > 0, "api.max_request_bytes");
    try require(config.api.max_result_count >= config.api.default_result_count, "api.max_result_count");
    try require(config.api.default_deadline_ms > 0, "api.default_deadline_ms");
    try require(config.api.entity_category_count <= 8, "api.entity_category_count");

    if (config.model.retained_dim != config.vector_index.retained_dimensions) {
        std.debug.print("configuration: model retained dimension must match index retained dimensions\n", .{});
        return ConfigurationError.IncompatibleComponents;
    }
    if (config.model.packed_bytes != config.vector_index.packed_vector_bytes) {
        return ConfigurationError.IncompatibleComponents;
    }
    if (config.vector_index.packed_vector_bytes * 8 != config.vector_index.retained_dimensions) {
        return ConfigurationError.IncompatibleComponents;
    }
    if (config.model.retained_dim % config.scoring.subvector_width != 0) {
        return ConfigurationError.IncompatibleComponents;
    }
    if (config.vector_index.shard_count > config.vector_index.centroid_count) {
        return ConfigurationError.IncompatibleComponents;
    }
    if (config.distributed.tls_enabled and std.mem.eql(u8, config.distributed.tls_backend, "none")) {
        return ConfigurationError.IncompatibleComponents;
    }
    return;
}

pub fn dataPath(allocator: std.mem.Allocator, base: []const u8, relative: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, relative });
}

pub fn ensureDirectory(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| {
        std.debug.print("configuration: unable to create directory {s}: {}\n", .{ path, err });
        return ConfigurationError.InvalidPath;
    };
}

pub fn ensureDirectories(config: *const Config, allocator: std.mem.Allocator) !void {
    try ensureDirectory(config.runtime.data_dir);
    try ensureDirectory(config.runtime.log_dir);
    try ensureDirectory(config.model.checkpoint_dir);
    try ensureDirectory(config.training.checkpoint_dir);
    try ensureDirectory(config.vector_index.index_dir);
    try ensureDirectory(config.storage.document_dir);
    try ensureDirectory(config.storage.metadata_dir);
    try ensureDirectory(config.storage.graph_dir);
    try ensureDirectory(config.storage.checkpoint_dir);
    try ensureDirectory(config.storage.transaction_log_dir);
    try ensureDirectory(config.telemetry.exporter_path);
    _ = allocator;
}


pub const HardwareProfile = struct {
    accelerator_name: []const u8,
    accelerators_per_node: u32,
    nodes: u32,
    memory_bytes_per_accelerator: u64,
    reference_nodes: u32,
    reference_batch_size: u32,
    compute_units: f64,

    pub fn fromConfig(config: *const TrainingConfig) HardwareProfile {
        const per_node: u64 = @intFromFloat(@max(1.0, config.memory_budget_gb_per_accelerator) * 1024.0 * 1024.0 * 1024.0);
        return .{
            .accelerator_name = config.accelerator_type,
            .accelerators_per_node = config.accelerator_count_per_node,
            .nodes = config.node_count,
            .memory_bytes_per_accelerator = per_node,
            .reference_nodes = config.h200_reference_node_count,
            .reference_batch_size = config.h200_reference_batch_size,
            .compute_units = @as(f64, @floatFromInt(config.node_count * config.accelerator_count_per_node)),
        };
    }

    pub fn totalAccelerators(self: HardwareProfile) u32 {
        return self.nodes * self.accelerators_per_node;
    }

    pub fn scaledBatchSize(self: HardwareProfile, configured: u32) u32 {
        const reference_total = @as(f64, @floatFromInt(@max(1, self.reference_nodes)));
        const scale = @as(f64, @floatFromInt(self.totalAccelerators())) / reference_total;
        const scaled = @as(f64, @floatFromInt(configured)) * @max(0.02, @min(4.0, scale));
        return @max(1, @as(u32, @intFromFloat(@round(scaled))));
    }

    pub fn gradientAccumulation(self: HardwareProfile, configured: u32) u32 {
        const reference_total = @as(f64, @floatFromInt(@max(1, self.reference_nodes)));
        const scale = @as(f64, @floatFromInt(self.totalAccelerators())) / reference_total;
        if (scale >= 1.0) return configured;
        return @max(1, @as(u32, @intFromFloat(@ceil(@as(f64, @floatFromInt(configured)) / @max(0.02, scale)))));
    }

    pub fn memoryBudgetBytes(self: HardwareProfile) u64 {
        return @as(u64, self.totalAccelerators()) * self.memory_bytes_per_accelerator;
    }

    pub fn detectedCpuCount(self: HardwareProfile) usize {
        _ = self;
        return platform.cpuCount();
    }
};

pub fn hardwareProfile(config: *const Config) HardwareProfile {
    return HardwareProfile.fromConfig(&config.training);
}
