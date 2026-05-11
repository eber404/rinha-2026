const std = @import("std");

pub const Features = struct {
    transaction_amount: f32 = 0.0,
    transaction_installments: i32 = 0,
    transaction_hour: u8 = 0,
    customer_avg_amount: f32 = 0.0,
    customer_tx_count_24h: i32 = 0,
    merchant_mcc: u16 = 0,
    terminal_km_from_home: f32 = 0.0,
    terminal_is_online: bool = false,
    terminal_card_present: bool = false,
    terminal_known_merchants: i32 = 0,
    last_transaction_minutes: i32 = 0,
    last_transaction_km_from_current: f32 = 0.0,
    merchant_avg_amount: f32 = 0.0,
    requested_at_hour: u8 = 0,
};

const Context = enum {
    root,
    transaction,
    customer,
    merchant,
    terminal,
    last_transaction,
};

fn skipWhitespace(buf: []const u8, i: *usize) void {
    while (i.* < buf.len and (buf[i.*] == ' ' or buf[i.*] == '\n' or buf[i.*] == '\r' or buf[i.*] == '\t')) {
        i.* += 1;
    }
}

fn skipColon(buf: []const u8, i: *usize) void {
    skipWhitespace(buf, i);
    if (i.* < buf.len and buf[i.*] == ':') {
        i.* += 1;
    }
    skipWhitespace(buf, i);
}

fn parseStringValue(buf: []const u8, i: *usize) []const u8 {
    skipWhitespace(buf, i);
    if (i.* < buf.len and buf[i.*] == '"') {
        i.* += 1;
    }
    const start = i.*;
    while (i.* < buf.len and buf[i.*] != '"') {
        i.* += 1;
    }
    const end = i.*;
    if (i.* < buf.len) i.* += 1;
    return buf[start..end];
}

fn parseNumber(buf: []const u8, i: *usize) f64 {
    skipWhitespace(buf, i);
    var negative = false;
    if (i.* < buf.len and buf[i.*] == '-') {
        negative = true;
        i.* += 1;
    }
    var value: f64 = 0.0;
    var seen_dot = false;
    var divisor: f64 = 1.0;
    while (i.* < buf.len) {
        const c = buf[i.*];
        if (c >= '0' and c <= '9') {
            value = value * 10.0 + @as(f64, @floatFromInt(c - '0'));
            if (seen_dot) divisor *= 10.0;
        } else if (c == '.' and !seen_dot) {
            seen_dot = true;
        } else {
            break;
        }
        i.* += 1;
    }
    if (negative) value = -value;
    return value / divisor;
}

fn parseI32(buf: []const u8, i: *usize) i32 {
    skipWhitespace(buf, i);
    var negative = false;
    if (i.* < buf.len and buf[i.*] == '-') {
        negative = true;
        i.* += 1;
    }
    var value: i32 = 0;
    while (i.* < buf.len) {
        const c = buf[i.*];
        if (c >= '0' and c <= '9') {
            value = value * 10 + @as(i32, @intCast(c - '0'));
        } else {
            break;
        }
        i.* += 1;
    }
    if (negative) value = -value;
    return value;
}

fn parseBool(buf: []const u8, i: *usize) bool {
    skipWhitespace(buf, i);
    if (i.* + 4 <= buf.len and std.mem.eql(u8, buf[i.*..i.* + 4], "true")) {
        i.* += 4;
        return true;
    }
    if (i.* + 5 <= buf.len and std.mem.eql(u8, buf[i.*..i.* + 5], "false")) {
        i.* += 5;
        return false;
    }
    return false;
}

fn parseISODateHour(buf: []const u8, i: *usize) u8 {
    skipWhitespace(buf, i);
    if (i.* < buf.len and buf[i.*] == '"') {
        i.* += 1;
    }
    var hour: u8 = 0;
    while (i.* < buf.len) {
        const c = buf[i.*];
        if (c == '"' or c == ',') break;
        if (c == 'T') {
            i.* += 1;
            if (i.* + 2 <= buf.len) {
                const h1 = buf[i.*];
                const h2 = buf[i.* + 1];
                if (h1 >= '0' and h1 <= '9' and h2 >= '0' and h2 <= '9') {
                    hour = @as(u8, (h1 - '0') * 10 + (h2 - '0'));
                }
                i.* += 2;
            }
            while (i.* < buf.len and buf[i.*] != '"' and buf[i.*] != ',') {
                i.* += 1;
            }
            break;
        }
        i.* += 1;
    }
    if (i.* < buf.len and buf[i.*] == '"') {
        i.* += 1;
    }
    return hour;
}

pub fn parsePayload(body: []const u8) Features {
    var f = Features{};
    var i: usize = 0;
    var ctx = Context.root;
    var prev_ctx = Context.root;

    while (i < body.len) {
        skipWhitespace(body, &i);
        if (i >= body.len) break;

        if (body[i] == '"') {
            const key_start = i + 1;
            var key_end = key_start;
            while (key_end < body.len and body[key_end] != '"') key_end += 1;
            const key = body[key_start..key_end];
            i = key_end + 1;

            skipColon(body, &i);

            if (ctx == Context.root) {
                if (std.mem.eql(u8, key, "transaction")) {
                    prev_ctx = ctx;
                    ctx = Context.transaction;
                } else if (std.mem.eql(u8, key, "customer")) {
                    prev_ctx = ctx;
                    ctx = Context.customer;
                } else if (std.mem.eql(u8, key, "merchant")) {
                    prev_ctx = ctx;
                    ctx = Context.merchant;
                } else if (std.mem.eql(u8, key, "terminal")) {
                    prev_ctx = ctx;
                    ctx = Context.terminal;
                } else if (std.mem.eql(u8, key, "last_transaction")) {
                    prev_ctx = ctx;
                    ctx = Context.last_transaction;
                } else if (std.mem.eql(u8, key, "requested_at")) {
                    f.requested_at_hour = parseISODateHour(body, &i);
                }
            } else if (ctx == Context.transaction) {
                if (std.mem.eql(u8, key, "amount")) {
                    f.transaction_amount = @as(f32, @floatCast(parseNumber(body, &i)));
                } else if (std.mem.eql(u8, key, "installments")) {
                    f.transaction_installments = parseI32(body, &i);
                } else if (std.mem.eql(u8, key, "requested_at")) {
                    f.transaction_hour = parseISODateHour(body, &i);
                }
            } else if (ctx == Context.customer) {
                if (std.mem.eql(u8, key, "avg_amount")) {
                    f.customer_avg_amount = @as(f32, @floatCast(parseNumber(body, &i)));
                } else if (std.mem.eql(u8, key, "tx_count_24h")) {
                    f.customer_tx_count_24h = parseI32(body, &i);
                }
            } else if (ctx == Context.merchant) {
                if (std.mem.eql(u8, key, "mcc")) {
                    const mcc_str = parseStringValue(body, &i);
                    f.merchant_mcc = parseMccString(mcc_str);
                } else if (std.mem.eql(u8, key, "avg_amount")) {
                    f.merchant_avg_amount = @as(f32, @floatCast(parseNumber(body, &i)));
                }
            } else if (ctx == Context.terminal) {
                if (std.mem.eql(u8, key, "km_from_home")) {
                    f.terminal_km_from_home = @as(f32, @floatCast(parseNumber(body, &i)));
                } else if (std.mem.eql(u8, key, "is_online")) {
                    f.terminal_is_online = parseBool(body, &i);
                } else if (std.mem.eql(u8, key, "card_present")) {
                    f.terminal_card_present = parseBool(body, &i);
                } else if (std.mem.eql(u8, key, "known_merchants")) {
                    f.terminal_known_merchants = parseI32(body, &i);
                }
            } else if (ctx == Context.last_transaction) {
                if (std.mem.eql(u8, key, "minutes")) {
                    f.last_transaction_minutes = parseI32(body, &i);
                } else if (std.mem.eql(u8, key, "km_from_current")) {
                    f.last_transaction_km_from_current = @as(f32, @floatCast(parseNumber(body, &i)));
                }
            }
        } else if (body[i] == '}') {
            i += 1;
            ctx = prev_ctx;
        } else if (body[i] == '[' or body[i] == ',') {
            i += 1;
        } else {
            i += 1;
        }
    }

    return f;
}

fn parseMccString(s: []const u8) u16 {
    var value: u16 = 0;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            value = value * 10 + @as(u16, @intCast(c - '0'));
        }
    }
    return value;
}
