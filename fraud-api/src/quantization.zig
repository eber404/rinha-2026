const std = @import("std");
const payload = @import("payload.zig");

pub const Features = payload.Features;
pub const QueryVector = [16]i8;

pub const QUANTIZATION_SCALES: [14]f32 = .{
    0.01, 0.1, 0.05, 0.01, 0.05, 0.01, 0.1, 1.0, 1.0, 0.05, 0.1, 0.01, 0.05, 0.01,
};

pub const QUANTIZATION_OFFSETS: [14]f32 = .{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};

fn quantizeDim(value: f32, scale: f32, offset: f32) i8 {
    const normalized = (value - offset) / scale;
    const quantized: i32 = @intFromFloat(std.math.round(normalized * 127.0));
    const clamped = std.math.clamp(quantized, @as(i32, -128), @as(i32, 127));
    return @as(i8, @intCast(clamped));
}

pub fn quantize(features: *const Features) QueryVector {
    var vec: QueryVector = undefined;
    @memset(&vec, 0);

    vec[0] = quantizeDim(@as(f32, features.transaction_amount), QUANTIZATION_SCALES[0], QUANTIZATION_OFFSETS[0]);
    vec[1] = quantizeDim(@floatFromInt(features.transaction_installments), QUANTIZATION_SCALES[1], QUANTIZATION_OFFSETS[1]);
    vec[2] = quantizeDim(@floatFromInt(features.transaction_hour), QUANTIZATION_SCALES[2], QUANTIZATION_OFFSETS[2]);
    vec[3] = quantizeDim(features.customer_avg_amount, QUANTIZATION_SCALES[3], QUANTIZATION_OFFSETS[3]);
    vec[4] = quantizeDim(@floatFromInt(features.customer_tx_count_24h), QUANTIZATION_SCALES[4], QUANTIZATION_OFFSETS[4]);
    vec[5] = quantizeDim(@floatFromInt(features.merchant_mcc), QUANTIZATION_SCALES[5], QUANTIZATION_OFFSETS[5]);
    vec[6] = quantizeDim(features.terminal_km_from_home, QUANTIZATION_SCALES[6], QUANTIZATION_OFFSETS[6]);
    vec[7] = quantizeDim(if (features.terminal_is_online) 1.0 else 0.0, QUANTIZATION_SCALES[7], QUANTIZATION_OFFSETS[7]);
    vec[8] = quantizeDim(if (features.terminal_card_present) 1.0 else 0.0, QUANTIZATION_SCALES[8], QUANTIZATION_OFFSETS[8]);
    vec[9] = quantizeDim(@floatFromInt(features.terminal_known_merchants), QUANTIZATION_SCALES[9], QUANTIZATION_OFFSETS[9]);
    vec[10] = quantizeDim(@floatFromInt(features.last_transaction_minutes), QUANTIZATION_SCALES[10], QUANTIZATION_OFFSETS[10]);
    vec[11] = quantizeDim(features.last_transaction_km_from_current, QUANTIZATION_SCALES[11], QUANTIZATION_OFFSETS[11]);
    vec[12] = quantizeDim(features.merchant_avg_amount, QUANTIZATION_SCALES[12], QUANTIZATION_OFFSETS[12]);
    vec[13] = quantizeDim(@floatFromInt(features.requested_at_hour), QUANTIZATION_SCALES[13], QUANTIZATION_OFFSETS[13]);

    return vec;
}