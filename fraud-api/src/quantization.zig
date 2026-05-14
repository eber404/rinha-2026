const std = @import("std");
const payload = @import("payload.zig");

pub const Features = payload.Features;
pub const QueryVector = [16]i16;

const MAX_AMOUNT: f32 = 10_000.0;
const MAX_INSTALLMENTS: f32 = 12.0;
const AMOUNT_VS_AVG_RATIO: f32 = 10.0;
const MAX_MINUTES: f32 = 1_440.0;
const MAX_KM: f32 = 1_000.0;
const MAX_TX_COUNT_24H: f32 = 20.0;
const MAX_MERCHANT_AVG_AMOUNT: f32 = 10_000.0;

fn quantizeDim(value: f32, scale: f32, offset: f32) i16 {
    const normalized = (value - offset) / scale;
    const quantized: i32 = @intFromFloat(std.math.round(normalized * 32767.0));
    const clamped = std.math.clamp(quantized, @as(i32, -32768), @as(i32, 32767));
    return @as(i16, @intCast(clamped));
}

pub fn quantize(features: *const Features) QueryVector {
    var vec: QueryVector = undefined;
    @memset(&vec, 0);

    const amount = std.math.clamp(features.transaction_amount / MAX_AMOUNT, 0.0, 1.0);
    const installments = std.math.clamp(@as(f32, @floatFromInt(features.transaction_installments)) / MAX_INSTALLMENTS, 0.0, 1.0);
    const amount_vs_avg = if (features.customer_avg_amount > 0.0)
        std.math.clamp((features.transaction_amount / features.customer_avg_amount) / AMOUNT_VS_AVG_RATIO, 0.0, 1.0)
    else
        0.0;
    const hour = @as(f32, @floatFromInt(features.transaction_hour)) / 23.0;
    const day_of_week = @as(f32, @floatFromInt(features.transaction_day_of_week)) / 6.0;
    const minutes_since_last = if (features.has_last_transaction)
        std.math.clamp(@as(f32, @floatFromInt(features.last_transaction_minutes)) / MAX_MINUTES, 0.0, 1.0)
    else
        -1.0;
    const km_since_last = if (features.has_last_transaction)
        std.math.clamp(features.last_transaction_km_from_current / MAX_KM, 0.0, 1.0)
    else
        -1.0;
    const km_from_home = std.math.clamp(features.terminal_km_from_home / MAX_KM, 0.0, 1.0);
    const tx_count = std.math.clamp(@as(f32, @floatFromInt(features.customer_tx_count_24h)) / MAX_TX_COUNT_24H, 0.0, 1.0);
    const merchant_avg = std.math.clamp(features.merchant_avg_amount / MAX_MERCHANT_AVG_AMOUNT, 0.0, 1.0);

    vec[0] = quantizeDim(amount, 1.0, 0.0);
    vec[1] = quantizeDim(installments, 1.0, 0.0);
    vec[2] = quantizeDim(amount_vs_avg, 1.0, 0.0);
    vec[3] = quantizeDim(hour, 1.0, 0.0);
    vec[4] = quantizeDim(day_of_week, 1.0, 0.0);
    vec[5] = quantizeDim(minutes_since_last, 1.0, 0.0);
    vec[6] = quantizeDim(km_since_last, 1.0, 0.0);
    vec[7] = quantizeDim(km_from_home, 1.0, 0.0);
    vec[8] = quantizeDim(tx_count, 1.0, 0.0);
    vec[9] = quantizeDim(if (features.terminal_is_online) 1.0 else 0.0, 1.0, 0.0);
    vec[10] = quantizeDim(if (features.terminal_card_present) 1.0 else 0.0, 1.0, 0.0);
    vec[11] = quantizeDim(if (features.merchant_unknown) 1.0 else 0.0, 1.0, 0.0);
    vec[12] = quantizeDim(features.mcc_risk, 1.0, 0.0);
    vec[13] = quantizeDim(merchant_avg, 1.0, 0.0);

    return vec;
}
