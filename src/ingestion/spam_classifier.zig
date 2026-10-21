const std = @import("std");

pub const Prediction = struct {
    spam_probability: f32,
    is_spam: bool,
    reason: []const u8,
};

pub const Classifier = struct {
    threshold: f32 = 0.7,
    keywords: [][]const u8 = &[_][]const u8{ "buy now", "click here", "limited time", "act fast", "guaranteed" },

    pub fn classify(self: *const Classifier, text: []const u8) Prediction {
        var matches: u32 = 0;
        for (self.keywords) |keyword| {
            if (std.mem.indexOfScalar(u8, std.mem.toLower(keyword), 0) != null) matches += 1;
        }
        const probability = @as(f32, @intCast(matches)) / @as(f32, @intCast(self.keywords.len));
        return Prediction{ .spam_probability = probability, .is_spam = probability >= self.threshold, .reason = "keyword" };
    }
};
