const std = @import("std");
const query_embeddings = @import("query_embeddings.zig");
const cluster_postings = @import("cluster_postings.zig");
const rendered_results = @import("rendered_results.zig");

pub const Coordinator = struct {
    query_embeddings: query_embeddings.Cache,
    cluster_postings: cluster_postings.Cache,
    rendered_results: rendered_results.Cache,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Coordinator {
        return Coordinator{
            .query_embeddings = try query_embeddings.Cache.init(allocator, 100000, 86400000),
            .cluster_postings = try cluster_postings.Cache.init(allocator, 50000, 3600000),
            .rendered_results = try rendered_results.Cache.init(allocator, 50000, 900000),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Coordinator) void {
        self.query_embeddings.deinit();
        self.cluster_postings.deinit();
        self.rendered_results.deinit();
    }

    pub fn invalidateModel(self: *Coordinator, model_version: u64) void {
        self.query_embeddings.invalidate(model_version);
        self.rendered_results.invalidate(model_version, 0);
    }

    pub fn invalidateIndex(self: *Coordinator, index_generation: u64) void {
        self.cluster_postings.invalidateGeneration(index_generation);
        self.rendered_results.invalidate(0, index_generation);
    }
};
