// Overflow a pooled stack on purpose: this must fault, not corrupt a neighbour.
const std = @import("std");
const Pool = @import("dod.zig").Pool;
const P = Pool(4, 64 * 1024);
var pool: P = undefined;
var dummy: u8 = 0;
noinline fn deep(n: u64) u64 {
    var buf: [1024]u8 = undefined;
    @memset(&buf, @truncate(n));
    std.mem.doNotOptimizeAway(&buf);
    return if (n == 0) buf[0] else deep(n - 1) +% buf[1];
}
fn task(_: *P, n: u64) void {
    std.debug.print("result {d}\n", .{deep(n)});
}
fn noBatch(_: *anyopaque, _: []const u64, _: []u64) void {}
pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.next();
    const n = try std.fmt.parseInt(u64, it.next().?, 10);
    try pool.init(&dummy);
    try pool.spawn(task, n);
    pool.run(noBatch, &dummy);
}
