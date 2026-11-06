const std = @import("std");
const efx = @import("efx");
const Log = efx.Effect(union(enum) { info: efx.Op(u64, u64) });
const Clock = efx.Effect(union(enum) { now: efx.Op(void, u64) });
const Disk = efx.Effect(union(enum) { write: efx.Op(u64, u64) });
pub const efx_effects = .{ Log, Clock, Disk };
const H = struct {
    pub fn info(_: *H, v: u64) u64 {
        return v + 1;
    }
    pub fn now(_: *H) u64 {
        return 100;
    }
};
const LogOnly = efx.View(.{Log});
const App = efx.View(.{ Log, Clock });
fn leaf(sc: *const LogOnly) u64 {
    return sc.exec(Clock, .now, {});
}
fn top(sc: *const App) u64 {
    return leaf(sc.narrow(LogOnly)) + sc.exec(Clock, .now, {});
}
pub fn main() void {
    var h = H{};
    const sc = efx.Scope.init(.{ .{ Log, &h }, .{ Clock, &h } });
    std.debug.print("{d}\n", .{top(App.of(&sc))});
}
