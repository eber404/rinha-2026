const std = @import("std");
const quantization = @import("../src/quantization.zig");

test "quantize defaults to zeros" {
    const f = quantization.Features{};
    const vec = quantization.quantize(&f);
    for (0..14) |i| {
        try std.testing.expectEqual(@as(i8, 0), vec[i]);
    }
}

test "quantize simple values" {
    var f = quantization.Features{};
    f.transaction_amount = 0.01;
    f.transaction_installments = 0;
    const vec = quantization.quantize(&f);
    try std.testing.expectEqual(@as(i8, 127), vec[0]);
    try std.testing.expectEqual(@as(i8, 0), vec[1]);
}

test "quantize smaller values don't clamp" {
    var f = quantization.Features{};
    f.transaction_amount = 0.005;
    const vec = quantization.quantize(&f);
    try std.testing.expect(vec[0] < 127);
    try std.testing.expect(vec[0] > 0);
}

test "quantize installments small value" {
    var f = quantization.Features{};
    f.transaction_installments = 1;
    const vec = quantization.quantize(&f);
    try std.testing.expectEqual(@as(i8, 127), vec[1]);
}

test "quantize clamping positive overflow" {
    var f = quantization.Features{};
    f.transaction_amount = 10000.0;
    const vec = quantization.quantize(&f);
    try std.testing.expectEqual(@as(i8, 127), vec[0]);
}

test "quantize clamping negative overflow" {
    var f = quantization.Features{};
    f.transaction_amount = -10000.0;
    const vec = quantization.quantize(&f);
    try std.testing.expectEqual(@as(i8, -128), vec[0]);
}

test "quantize bools converted to 0/1" {
    var f = quantization.Features{};
    f.terminal_is_online = false;
    f.terminal_card_present = false;
    const vec = quantization.quantize(&f);
    try std.testing.expectEqual(@as(i8, 0), vec[7]);
    try std.testing.expectEqual(@as(i8, 0), vec[8]);
}

test "quantize all dimensions have valid values" {
    var f = quantization.Features{};
    f.transaction_amount = 50.0;
    f.transaction_installments = 3;
    f.transaction_hour = 12;
    f.customer_avg_amount = 100.0;
    f.customer_tx_count_24h = 5;
    f.merchant_mcc = 5411;
    f.terminal_km_from_home = 1.5;
    f.terminal_is_online = true;
    f.terminal_card_present = true;
    f.terminal_known_merchants = 10;
    f.last_transaction_minutes = 30;
    f.last_transaction_km_from_current = 0.5;
    f.merchant_avg_amount = 200.0;
    f.requested_at_hour = 9;
    const vec = quantization.quantize(&f);
    for (0..14) |i| {
        try std.testing.expect(vec[i] >= -128 and vec[i] <= 127);
    }
}

test "quantize padding zeros" {
    var f = quantization.Features{};
    const vec = quantization.quantize(&f);
    try std.testing.expectEqual(@as(i8, 0), vec[14]);
    try std.testing.expectEqual(@as(i8, 0), vec[15]);
}