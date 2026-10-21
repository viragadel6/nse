const std = @import("std");
const contrastive = @import("contrastive_loss.zig");

pub const Weights = struct {
    retrieval: f32 = 1.0,
    url_prediction: f32 = 0.25,
    entity: f32 = 0.1,
    passage: f32 = 0.1,
    paragraph: f32 = 0.1,
    link: f32 = 0.2,
    distillation: f32 = 0,
};

pub const Loss = struct {
    weights: Weights,
    contrastive: contrastive.Loss,

    pub fn init() Loss {
        return Loss{ .weights = .{}, .contrastive = .{} };
    }

    pub fn forward(self: *Loss, retrieval_loss: f32, url_loss: f32, entity_loss: f32, passage_loss: f32, paragraph_loss: f32, link_loss: f32, distillation_loss: f32) !struct { total: f32, components: [7]f32 } {
        if (!std.math.isFinite(retrieval_loss) or !std.math.isFinite(url_loss) or !std.math.isFinite(entity_loss) or !std.math.isFinite(passage_loss) or !std.math.isFinite(paragraph_loss) or !std.math.isFinite(link_loss) or !std.math.isFinite(distillation_loss)) return error.NonFiniteTrainingLoss;
        var components = [_]f32{ retrieval_loss, url_loss, entity_loss, passage_loss, paragraph_loss, link_loss, distillation_loss };
        var total: f32 = 0;
        var i: usize = 0;
        while (i < 7) {
            const weight = switch (i) {
                0 => self.weights.retrieval,
                1 => self.weights.url_prediction,
                2 => self.weights.entity,
                3 => self.weights.passage,
                4 => self.weights.paragraph,
                5 => self.weights.link,
                else => self.weights.distillation,
            };
            total += components[i] * weight;
            i += 1;
        }
        return .{ .total = total, .components = components };
    }
};
