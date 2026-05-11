const std = @import("std");
const scorer = @import("../src/scorer.zig");
const dataset = @import("../src/dataset.zig");

test "topk insert maintains order" {
    var tk = scorer.TopK.init();
    tk.insert(100, 0);
    tk.insert(50, 1);
    tk.insert(75, 2);
    try std.testing.expect(tk.count == 3);
    try std.testing.expect(tk.distances[0] == 100);
    try std.testing.expect(tk.distances[1] == 50);
    try std.testing.expect(tk.distances[2] == 75);
}

test "topk insert replaces worst when full" {
    var tk = scorer.TopK.init();
    tk.insert(100, 0);
    tk.insert(90, 1);
    tk.insert(80, 2);
    tk.insert(70, 3);
    tk.insert(60, 4);
    try std.testing.expect(tk.count == 5);

    tk.insert(55, 5);
    try std.testing.expect(tk.count == 5);
    var worst: i32 = 0;
    for (0..tk.count) |i| {
        if (tk.distances[i] > worst) worst = tk.distances[i];
    }
    try std.testing.expect(worst == 90);
}

test "topk reset clears state" {
    var tk = scorer.TopK.init();
    tk.insert(100, 0);
    tk.reset();
    try std.testing.expect(tk.count == 0);
}

test "distance identical vectors" {
    const q: scorer.QueryVector = [_]i8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const v = [_]i8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const d = scorer.distance(&q, &v);
    try std.testing.expectEqual(@as(i32, 0), d);
}

test "distance differs" {
    const q: scorer.QueryVector = [_]i8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const v = [_]i8{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
    const d = scorer.distance(&q, &v);
    try std.testing.expectEqual(@as(i32, 16), d);
}

test "distance with negative values" {
    const q: scorer.QueryVector = [_]i8{ -10, -10, -10, -10, -10, -10, -10, -10, -10, -10, -10, -10, -10, -10, -10, -10 };
    const v = [_]i8{ 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10 };
    const d = scorer.distance(&q, &v);
    try std.testing.expectEqual(@as(i32, 400 * 16), d);
}

test "scorer empty dataset returns zero" {
    var d = dataset.Dataset.init();
    defer d.deinit();
    var s = scorer.Scorer.init(&d);
    const q: scorer.QueryVector = [_]i8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const score = s.score(&q);
    try std.testing.expectEqual(@as(f32, 0.0), score);
}

test "scoreWithRefIndexCount zero ref returns zero" {
    var d = dataset.Dataset.init();
    defer d.deinit();
    var s = scorer.Scorer.init(&d);
    const q: scorer.QueryVector = [_]i8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const score = s.scoreWithRefIndexCount(&q, 0);
    try std.testing.expectEqual(@as(f32, 0.0), score);
}