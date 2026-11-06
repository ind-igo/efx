const std = @import("std");
const efx = @import("efx");
const Co = @import("co.zig").Co;
const K = Co(u64, u64, u64);
const n = 20_000_000;
fn body(k: *K, _: *anyopaque) error{Aborted}!u64 {
    var x: u64 = 0;
    for (0..n) |i| x +%= try k.perform(i);
    return x;
}
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var dummy: u8 = 0;
    for (0..5) |_| {
        var k = try K.init(body, &dummy);
        defer k.deinit();
        const t0 = std.Io.Timestamp.now(io, .awake);
        var ev = k.start();
        while (ev == .perform) ev = k.@"resume"(ev.perform);
        const d = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
        std.debug.print("perform+resume: {d:.2} ns/roundtrip (check {d})\n", .{ @as(f64, @floatFromInt(d)) / n, try ev.done });
    }
    const t0 = std.Io.Timestamp.now(io, .awake);
    var keep: [64]K = undefined;
    for (&keep) |*k| k.* = try K.init(body, &dummy);
    for (&keep) |*k| k.deinit();
    const d = t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    std.debug.print("create+destroy continuation stack (256KiB): {d:.0} ns each\n", .{@as(f64, @floatFromInt(d)) / 64});
}
