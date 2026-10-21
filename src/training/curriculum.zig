const std = @import("std");

pub const Stage = enum(u8) {
    link_prediction = 1,
    contrastive_retrieval = 2,
    hard_negative = 3,
    structural_modeling = 4,
    code_search = 5,
    executive_profile = 6,
    research_document = 7,
    domain_calibration = 8,
};

pub const StageConfig = struct {
    stage: Stage,
    steps: u32,
    learning_rate: f32,
    batch_size: u32,
    gradient_clip: f32,
    warmup_steps: u32,
    checkpoint_interval: u32,
    validation_threshold: f32 = 0,
};

pub const Curriculum = struct {
    stages: []const StageConfig,
    current: usize = 0,

    pub fn init(stages: []const StageConfig) Curriculum {
        return Curriculum{ .stages = stages };
    }

    pub fn currentStage(self: *const Curriculum) StageConfig {
        return self.stages[self.current];
    }

    pub fn advance(self: *Curriculum) bool {
        if (self.current + 1 < self.stages.len) {
            self.current += 1;
            return true;
        }
        return false;
    }

    pub fn isComplete(self: *const Curriculum) bool {
        return self.current >= self.stages.len;
    }
};

pub const defaultStages: [8]StageConfig = .{
    StageConfig{ .stage = .link_prediction, .steps = 100000, .learning_rate = 0.0003, .batch_size = 256, .gradient_clip = 1, .warmup_steps = 1000, .checkpoint_interval = 5000 },
    StageConfig{ .stage = .contrastive_retrieval, .steps = 200000, .learning_rate = 0.0001, .batch_size = 512, .gradient_clip = 1, .warmup_steps = 2000, .checkpoint_interval = 10000 },
    StageConfig{ .stage = .hard_negative, .steps = 150000, .learning_rate = 0.00005, .batch_size = 512, .gradient_clip = 0.5, .warmup_steps = 1000, .checkpoint_interval = 10000 },
    StageConfig{ .stage = .structural_modeling, .steps = 100000, .learning_rate = 0.0001, .batch_size = 256, .gradient_clip = 1, .warmup_steps = 1000, .checkpoint_interval = 5000 },
    StageConfig{ .stage = .code_search, .steps = 80000, .learning_rate = 0.0001, .batch_size = 256, .gradient_clip = 1, .warmup_steps = 1000, .checkpoint_interval = 5000 },
    StageConfig{ .stage = .executive_profile, .steps = 80000, .learning_rate = 0.0001, .batch_size = 256, .gradient_clip = 1, .warmup_steps = 1000, .checkpoint_interval = 5000 },
    StageConfig{ .stage = .research_document, .steps = 80000, .learning_rate = 0.0001, .batch_size = 256, .gradient_clip = 1, .warmup_steps = 1000, .checkpoint_interval = 5000 },
    StageConfig{ .stage = .domain_calibration, .steps = 50000, .learning_rate = 0.00002, .batch_size = 512, .gradient_clip = 0.5, .warmup_steps = 500, .checkpoint_interval = 2500 },
};
