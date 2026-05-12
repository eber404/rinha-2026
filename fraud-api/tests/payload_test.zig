const std = @import("std");
const payload = @import("../src/payload.zig");

test "parse simple transaction" {
    const body = "{\"transaction\":{\"amount\":150.5,\"installments\":3}}";
    const f = payload.parsePayload(body);
    try std.testing.expectEqual(@as(f32, 150.5), f.transaction_amount);
    try std.testing.expectEqual(@as(i32, 3), f.transaction_installments);
}

test "parse all fields" {
    const body = "{\"transaction\":{\"amount\":100,\"installments\":1,\"requested_at\":\"2024-01-15T14:30:00Z\"},\"customer\":{\"avg_amount\":50,\"tx_count_24h\":5},\"merchant\":{\"mcc\":\"5411\",\"avg_amount\":200},\"terminal\":{\"km_from_home\":1.5,\"is_online\":true,\"card_present\":false,\"known_merchants\":10},\"last_transaction\":{\"minutes\":30,\"km_from_current\":0.5},\"requested_at\":\"2024-01-15T09:00:00Z\"}";
    const f = payload.parsePayload(body);
    try std.testing.expectEqual(@as(f32, 100.0), f.transaction_amount);
    try std.testing.expectEqual(@as(i32, 1), f.transaction_installments);
    try std.testing.expectEqual(@as(u8, 14), f.transaction_hour);
    try std.testing.expectEqual(@as(f32, 50.0), f.customer_avg_amount);
    try std.testing.expectEqual(@as(i32, 5), f.customer_tx_count_24h);
    try std.testing.expectEqual(@as(u16, 5411), f.merchant_mcc);
    try std.testing.expectEqual(@as(f32, 1.5), f.terminal_km_from_home);
    try std.testing.expectEqual(true, f.terminal_is_online);
    try std.testing.expectEqual(false, f.terminal_card_present);
    try std.testing.expectEqual(@as(i32, 10), f.terminal_known_merchants);
    try std.testing.expectEqual(@as(i32, 30), f.last_transaction_minutes);
    try std.testing.expectEqual(@as(f32, 0.5), f.last_transaction_km_from_current);
    try std.testing.expectEqual(@as(f32, 200.0), f.merchant_avg_amount);
    try std.testing.expectEqual(@as(u8, 9), f.requested_at_hour);
}

test "defaults for missing fields" {
    const body = "{}";
    const f = payload.parsePayload(body);
    try std.testing.expectEqual(@as(f32, 0.0), f.transaction_amount);
    try std.testing.expectEqual(@as(i32, 0), f.transaction_installments);
    try std.testing.expectEqual(@as(u8, 0), f.transaction_hour);
    try std.testing.expectEqual(@as(f32, 0.0), f.customer_avg_amount);
    try std.testing.expectEqual(@as(u16, 0), f.merchant_mcc);
    try std.testing.expectEqual(false, f.terminal_is_online);
    try std.testing.expectEqual(false, f.terminal_card_present);
}

test "disambiguate customer vs merchant avg_amount" {
    const body = "{\"customer\":{\"avg_amount\":123.45},\"merchant\":{\"avg_amount\":678.90}}";
    const f = payload.parsePayload(body);
    try std.testing.expectEqual(@as(f32, 123.45), f.customer_avg_amount);
    try std.testing.expectEqual(@as(f32, 678.90), f.merchant_avg_amount);
}

test "parse mcc string" {
    const mcc = payload.parseMccString("5411");
    try std.testing.expectEqual(@as(u16, 5411), mcc);
}

test "parse negative numbers" {
    const body = "{\"transaction\":{\"amount\":-50.25,\"installments\":-2}}";
    const f = payload.parsePayload(body);
    try std.testing.expectEqual(@as(f32, -50.25), f.transaction_amount);
    try std.testing.expectEqual(@as(i32, -2), f.transaction_installments);
}

test "parse official high-risk payload fields" {
    const body = "{\"id\":\"tx-3330991687\",\"transaction\":{\"amount\":9505.97,\"installments\":10,\"requested_at\":\"2026-03-14T05:15:12Z\"},\"customer\":{\"avg_amount\":81.28,\"tx_count_24h\":20,\"known_merchants\":[\"MERC-008\",\"MERC-007\",\"MERC-005\"]},\"merchant\":{\"id\":\"MERC-068\",\"mcc\":\"7802\",\"avg_amount\":54.86},\"terminal\":{\"is_online\":false,\"card_present\":true,\"km_from_home\":952.27},\"last_transaction\":null}";
    const f = payload.parsePayload(body);
    try std.testing.expectEqual(@as(f32, 9505.97), f.transaction_amount);
    try std.testing.expectEqual(@as(i32, 10), f.transaction_installments);
    try std.testing.expectEqual(@as(f32, 81.28), f.customer_avg_amount);
    try std.testing.expectEqual(@as(i32, 20), f.customer_tx_count_24h);
    try std.testing.expectEqual(@as(f32, 952.27), f.terminal_km_from_home);
}
