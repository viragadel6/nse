const std = @import("std");

pub const Features = struct {
    lexical: f64 = 0,
    semantic: f64 = 0,
    freshness: f64 = 0,
    quality: f64 = 0,
    authority: f64 = 0,
    graph_quality: f64 = 0,
    originality: f64 = 0,
};

pub const Combiner = struct {
    lexical_weight: f64 = 0.4,
    semantic_weight: f64 = 0.4,
    freshness_weight: f64 = 0.1,
    quality_weight: f64 = 0.1,

    pub fn combine(self: *const Combiner, features: Features) f64 {
        return self.lexical_weight * features.lexical + self.semantic_weight * features.semantic + self.freshness_weight * features.freshness + self.quality_weight * features.quality;
    }
};
