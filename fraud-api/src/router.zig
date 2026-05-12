const std = @import("std");
const payload = @import("payload.zig");
const quantization = @import("quantization.zig");
const scorer = @import("scorer.zig");
const dataset = @import("dataset.zig");

const static_404 = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";
const static_405 = "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 17\r\n\r\nMethod Not Allowed";

threadlocal var fraud_response_buf: [2048]u8 = undefined;
threadlocal var ready_http_buf: [2048]u8 = undefined;

var global_dataset: dataset.Dataset = undefined;
var global_scorer: scorer.Scorer = undefined;
var scorer_initialized = false;

fn computeFallbackScore(f: payload.Features) f32 {
    var score: f32 = 0.0;

    if (f.transaction_amount > f.customer_avg_amount * 3.0) score += 0.3;
    if (f.transaction_installments > 6) score += 0.15;
    if (f.customer_tx_count_24h < 3) score += 0.2;
    if (f.terminal_km_from_home > 100.0) score += 0.25;
    if (f.last_transaction_minutes > 0 and f.last_transaction_minutes < 5) score += 0.3;
    if (!f.terminal_is_online and !f.terminal_card_present) score += 0.15;
    if (f.merchant_mcc == 5411 and f.transaction_amount > 1000) score += 0.2;

    return @min(score, 1.0);
}

pub fn initScorer(data_dir: []const u8) void {
    if (scorer_initialized) return;
    global_dataset = dataset.Dataset.init();
    global_dataset.load(data_dir) catch return;
    global_scorer = scorer.Scorer.init(&global_dataset);
    scorer_initialized = true;
}

pub fn route(method: []const u8, path: []const u8, body: []const u8, instance_id: []const u8) []const u8 {
    if (path.len == 12 and std.mem.eql(u8, path, "/fraud-score")) {
        if (method.len == 4 and std.mem.eql(u8, method, "POST")) {
            return handleFraudScore(body, instance_id);
        }
        return static_405;
    }
    if (path.len == 6 and std.mem.eql(u8, path, "/ready")) {
        if (method.len == 3 and std.mem.eql(u8, method, "GET")) {
            return buildReadyResponse(instance_id);
        }
        return static_405;
    }
    return static_404;
}

fn buildReadyResponse(instance: []const u8) []const u8 {
    const inst_len = instance.len;
    const json_len = 28 + inst_len;
    var pos: usize = 0;

    @memcpy(ready_http_buf[pos..pos+8], "HTTP/1.1");
    pos += 8;
    ready_http_buf[pos] = ' ';
    pos += 1;
    @memcpy(ready_http_buf[pos..pos+3], "200");
    pos += 3;
    ready_http_buf[pos] = ' ';
    pos += 1;
    @memcpy(ready_http_buf[pos..pos+2], "OK");
    pos += 2;
    ready_http_buf[pos] = 13;
    pos += 1;
    ready_http_buf[pos] = 10;
    pos += 1;
    @memcpy(ready_http_buf[pos..pos+13], "Content-Type:");
    pos += 13;
    ready_http_buf[pos] = ' ';
    pos += 1;
    @memcpy(ready_http_buf[pos..pos+16], "application/json");
    pos += 16;
    ready_http_buf[pos] = 13;
    pos += 1;
    ready_http_buf[pos] = 10;
    pos += 1;
    @memcpy(ready_http_buf[pos..pos+16], "Content-Length: ");
    pos += 16;

    const len_str = std.fmt.bufPrint(ready_http_buf[pos..pos+4], "{d}", .{json_len}) catch unreachable;
    pos += len_str.len;
    ready_http_buf[pos] = 13;
    pos += 1;
    ready_http_buf[pos] = 10;
    pos += 1;
    ready_http_buf[pos] = 13;
    pos += 1;
    ready_http_buf[pos] = 10;
    pos += 1;

    ready_http_buf[pos] = '{';
    pos += 1;
    ready_http_buf[pos] = '"';
    pos += 1;
    @memcpy(ready_http_buf[pos..pos+5], "ready");
    pos += 5;
    ready_http_buf[pos] = '"';
    pos += 1;
    ready_http_buf[pos] = ':';
    pos += 1;
    @memcpy(ready_http_buf[pos..pos+4], "true");
    pos += 4;
    ready_http_buf[pos] = ',';
    pos += 1;
    ready_http_buf[pos] = '"';
    pos += 1;
    @memcpy(ready_http_buf[pos..pos+8], "instance");
    pos += 8;
    ready_http_buf[pos] = '"';
    pos += 1;
    ready_http_buf[pos] = ':';
    pos += 1;
    ready_http_buf[pos] = '"';
    pos += 1;
    @memcpy(ready_http_buf[pos..pos+inst_len], instance);
    pos += inst_len;
    ready_http_buf[pos] = '"';
    pos += 1;
    ready_http_buf[pos] = '}';
    pos += 1;

    return ready_http_buf[0..pos];
}

fn handleFraudScore(body: []const u8, instance_id: []const u8) []const u8 {
    const f = payload.parsePayload(body);
    const score: f32 = blk: {
        if (!scorer_initialized) break :blk computeFallbackScore(f);
        const query = quantization.quantize(&f);
        break :blk global_scorer.score(&query);
    };
    const approved = score < 0.6;
    var score_str_buf: [32]u8 = undefined;
    const score_str = std.fmt.bufPrint(&score_str_buf, "{d}", .{score}) catch unreachable;
    const instance_len = instance_id.len;
    const body_len = 12 + @as(usize, if (approved) 4 else 5) + 15 + score_str.len + 13 + instance_len + 2;

    var pos: usize = 0;
    @memcpy(fraud_response_buf[pos..pos+8], "HTTP/1.1");
    pos += 8;
    fraud_response_buf[pos] = ' ';
    pos += 1;
    @memcpy(fraud_response_buf[pos..pos+3], "200");
    pos += 3;
    fraud_response_buf[pos] = ' ';
    pos += 1;
    @memcpy(fraud_response_buf[pos..pos+2], "OK");
    pos += 2;
    fraud_response_buf[pos] = 13;
    pos += 1;
    fraud_response_buf[pos] = 10;
    pos += 1;
    @memcpy(fraud_response_buf[pos..pos+13], "Content-Type:");
    pos += 13;
    fraud_response_buf[pos] = ' ';
    pos += 1;
    @memcpy(fraud_response_buf[pos..pos+16], "application/json");
    pos += 16;
    fraud_response_buf[pos] = 13;
    pos += 1;
    fraud_response_buf[pos] = 10;
    pos += 1;
    @memcpy(fraud_response_buf[pos..pos+16], "Content-Length: ");
    pos += 16;

    const len_slice = std.fmt.bufPrint(fraud_response_buf[pos..pos+6], "{d}", .{body_len}) catch unreachable;
    pos += len_slice.len;
    fraud_response_buf[pos] = 13;
    pos += 1;
    fraud_response_buf[pos] = 10;
    pos += 1;
    fraud_response_buf[pos] = 13;
    pos += 1;
    fraud_response_buf[pos] = 10;
    pos += 1;

    @memcpy(fraud_response_buf[pos..pos+12], "{\"approved\":");
    pos += 12;
    if (approved) {
        @memcpy(fraud_response_buf[pos..pos+4], "true");
        pos += 4;
    } else {
        @memcpy(fraud_response_buf[pos..pos+5], "false");
        pos += 5;
    }
    @memcpy(fraud_response_buf[pos..pos+15], ",\"fraud_score\":");
    pos += 15;
    @memcpy(fraud_response_buf[pos..pos+score_str.len], score_str);
    pos += score_str.len;
    @memcpy(fraud_response_buf[pos..pos+13], ",\"instance\":\"");
    pos += 13;
    @memcpy(fraud_response_buf[pos..pos+instance_len], instance_id);
    pos += instance_len;
    @memcpy(fraud_response_buf[pos..pos+2], "\"}");
    pos += 2;

    return fraud_response_buf[0..pos];
}
