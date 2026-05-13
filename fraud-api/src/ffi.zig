const std = @import("std");
const dataset = @import("dataset.zig");
const scorer = @import("scorer.zig");
const quantization = @import("quantization.zig");

pub const ScoreReq = extern struct {
    transaction_amount: f32,
    transaction_installments: i32,
    transaction_hour: u8,
    transaction_day_of_week: u8,
    customer_avg_amount: f32,
    customer_tx_count_24h: i32,
    merchant_unknown: u8,
    mcc_risk: f32,
    merchant_mcc: u16,
    terminal_km_from_home: f32,
    terminal_is_online: u8,
    terminal_card_present: u8,
    terminal_known_merchants: i32,
    last_transaction_minutes: i32,
    last_transaction_km_from_current: f32,
    merchant_avg_amount: f32,
    requested_at_hour: u8,
    has_last_transaction: u8,
};

pub const ScoreRes = extern struct {
    score: f32,
    err_code: u8,
};

pub const CoreStats = extern struct {
    requests: u64,
    fallback_hits: u64,
    fallback_scanned_vectors: u64,
    cluster_scanned_vectors: u64,
};

var global_dataset: dataset.Dataset = undefined;
var global_scorer: scorer.Scorer = undefined;
var initialized = false;

pub export fn score_abi_version() callconv(.c) u32 {
    return 1;
}

pub export fn score_init(data_dir: [*:0]const u8) callconv(.c) u8 {
    if (initialized) return 0;
    global_dataset = dataset.Dataset.init();
    global_dataset.load(std.mem.span(data_dir)) catch return 1;
    global_scorer = scorer.Scorer.init(&global_dataset);
    initialized = true;
    return 0;
}

pub export fn score_eval(req: *const ScoreReq, res: *ScoreRes) callconv(.c) u8 {
    if (!initialized) {
        res.* = .{ .score = 0.0, .err_code = 1 };
        return 1;
    }

    const features = quantization.Features{
        .transaction_amount = req.transaction_amount,
        .transaction_installments = req.transaction_installments,
        .transaction_hour = req.transaction_hour,
        .transaction_day_of_week = req.transaction_day_of_week,
        .customer_avg_amount = req.customer_avg_amount,
        .customer_tx_count_24h = req.customer_tx_count_24h,
        .merchant_unknown = req.merchant_unknown != 0,
        .mcc_risk = req.mcc_risk,
        .merchant_mcc = req.merchant_mcc,
        .terminal_km_from_home = req.terminal_km_from_home,
        .terminal_is_online = req.terminal_is_online != 0,
        .terminal_card_present = req.terminal_card_present != 0,
        .terminal_known_merchants = req.terminal_known_merchants,
        .last_transaction_minutes = req.last_transaction_minutes,
        .last_transaction_km_from_current = req.last_transaction_km_from_current,
        .merchant_avg_amount = req.merchant_avg_amount,
        .requested_at_hour = req.requested_at_hour,
        .has_last_transaction = req.has_last_transaction != 0,
    };

    const q = quantization.quantize(&features);
    res.* = .{ .score = global_scorer.score(&q), .err_code = 0 };
    return 0;
}

pub export fn score_shutdown() callconv(.c) void {
    if (!initialized) return;
    global_dataset.deinit();
    initialized = false;
}

pub export fn score_stats(out: *CoreStats) callconv(.c) void {
    out.* = .{
        .requests = scorer.runtime_stats.requests.load(.monotonic),
        .fallback_hits = scorer.runtime_stats.fallback_hits.load(.monotonic),
        .fallback_scanned_vectors = scorer.runtime_stats.fallback_scanned_vectors.load(.monotonic),
        .cluster_scanned_vectors = scorer.runtime_stats.cluster_scanned_vectors.load(.monotonic),
    };
}
