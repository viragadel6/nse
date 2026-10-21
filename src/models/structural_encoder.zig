const std = @import("std");

pub const SpanFeature = struct {
    heading_depth: u8,
    dom_depth: u8,
    element_type: u8,
    visual_prominence: f32,
    paragraph_position: u32,
    link_context: bool,
    document_location: f32,
};

pub const StructuralEncoder = struct {
    feature_dim: u16 = 64,

    pub fn encode(self: *const StructuralEncoder, span: []const u8, feature: SpanFeature, output: []f32) void {
        var i: usize = 0;
        while (i < output.len) output[i] = 0;
        if (feature.heading_depth > 0) output[@as(usize, @intCast(feature.heading_depth)) % output.len] = feature.visual_prominence;
        if (feature.link_context) output[output.len / 2] = 1.0;
        const location_slot = @as(usize, @f2u(usize, feature.document_location * @as(f64, @intCast(output.len)))) % output.len;
        output[location_slot] = feature.document_location;
    }
};
