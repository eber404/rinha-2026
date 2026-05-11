const std = @import("std");
const dataset = @import("../src/dataset.zig");

test "dataset init and deinit" {
    var d = dataset.Dataset.init();
    defer d.deinit();
    try std.testing.expect(d.vectors_fd == -1);
}

test "dataset empty access returns zero" {
    var d = dataset.Dataset.init();
    defer d.deinit();
    try std.testing.expectEqual(@as(i8, 0), d.vectorAt(0, 0));
    try std.testing.expectEqual(@as(u8, 0), d.labelAt(0));
    try std.testing.expectEqual(@as(u32, 0), d.clusterRange(0).start);
    try std.testing.expectEqual(@as(u32, 0), d.clusterRange(0).end);
}