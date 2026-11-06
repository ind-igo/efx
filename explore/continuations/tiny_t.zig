const std = @import("std");
const efx = @import("efx");
const Pool = @import("tiny.zig").Pool;
const t = std.testing;

// The business logic: one effect, no idea whether it parks.
const Store = efx.Effect(union(enum) { get: efx.Op(u64, error{Aborted}!u64) });

fn chase(sc: *const efx.Scope, start: u64, hops: u32) error{Aborted}!u64 {
    var k = start;
    for (0..hops) |_| k = try Store.exec(sc, .get, k);
    return k;
}

const P = Pool(256, 64 * 1024);
var pool: P = undefined;
var ready = false;

fn setup() !void {
    if (!ready) try pool.init(&ready);
    ready = true;
}

const Direct = struct {
    calls: u32 = 0,
    pub fn get(self: *Direct, k: u64) error{Aborted}!u64 {
        self.calls += 1;
        return k *% 3 +% 1;
    }
};

const Parking = struct {
    pub fn get(_: *Parking, k: u64) error{Aborted}!u64 {
        return pool.perform(k);
    }
};

const Ctx = struct {
    sc: *const efx.Scope,
    hops_of: *const fn (u64) u32 = fixed,
    sum: u64 = 0,
    finished: u32 = 0,
    unwound: u32 = 0,
    fn fixed(_: u64) u32 {
        return 10;
    }
};

fn task(p: *P, input: u64) void {
    const c: *Ctx = @ptrCast(@alignCast(p.user));
    defer c.finished += 1;
    const r = chase(c.sc, input, c.hops_of(input)) catch |e| {
        std.debug.assert(e == error.Aborted);
        c.unwound += 1;
        return;
    };
    c.sum +%= r;
}

const Backend = struct {
    batches: u32 = 0,
    rows: u32 = 0,
    fn batch(ctx: *anyopaque, values: []u64) void {
        const self: *Backend = @ptrCast(@alignCast(ctx));
        self.batches += 1;
        self.rows += @intCast(values.len);
        for (values) |*v| v.* = v.* *% 3 +% 1;
    }
};

test "same business logic: direct call, and parked on the pool" {
    try setup();
    var direct = Direct{};
    const direct_scope = efx.Scope.init(.{.{ Store, &direct }});
    var expected: u64 = 0;
    for (0..100) |i| expected +%= try chase(&direct_scope, i, 10);

    var parking = Parking{};
    const sc = efx.Scope.init(.{.{ Store, &parking }});
    var c = Ctx{ .sc = &sc };
    pool.user = &c;
    var backend = Backend{};
    for (0..100) |i| try pool.spawn(task, i);
    pool.run(Backend.batch, &backend);

    try t.expectEqual(expected, c.sum);
    try t.expectEqual(@as(u32, 10), backend.batches);
    try t.expectEqual(@as(u32, 1000), backend.rows);
}

test "tasks ending at different times: later rows keep their own replies" {
    try setup();
    const Hops = struct {
        fn of(input: u64) u32 {
            return @intCast(input % 7);
        }
    };
    var direct = Direct{};
    const direct_scope = efx.Scope.init(.{.{ Store, &direct }});
    var expected: u64 = 0;
    for (0..200) |i| expected +%= try chase(&direct_scope, i, Hops.of(i));

    var parking = Parking{};
    const sc = efx.Scope.init(.{.{ Store, &parking }});
    var c = Ctx{ .sc = &sc, .hops_of = Hops.of };
    pool.user = &c;
    var backend = Backend{};
    for (0..200) |i| try pool.spawn(task, i);
    pool.run(Backend.batch, &backend);

    try t.expectEqual(expected, c.sum);
    try t.expectEqual(@as(u32, 200), c.finished);
    try t.expectEqual(@as(u32, 6), backend.batches);
}

test "cancel: parked tasks unwind, defers run, every stack is recycled" {
    try setup();
    var parking = Parking{};
    const sc = efx.Scope.init(.{.{ Store, &parking }});
    var c = Ctx{ .sc = &sc };
    pool.user = &c;
    for (0..50) |i| try pool.spawn(task, i);
    try t.expectEqual(@as(u32, 50), pool.len);

    pool.cancel();

    try t.expectEqual(@as(u32, 50), c.unwound);
    try t.expectEqual(@as(u32, 50), c.finished);
    try t.expectEqual(@as(u32, 0), pool.len);
    try t.expectEqual(@as(u32, 256), pool.free_len);
}

test "stacks recycle: 100x capacity through a bounded pool" {
    try setup();
    var parking = Parking{};
    const sc = efx.Scope.init(.{.{ Store, &parking }});
    var c = Ctx{ .sc = &sc };
    pool.user = &c;
    var backend = Backend{};
    for (0..100) |_| {
        for (0..256) |i| try pool.spawn(task, i);
        pool.run(Backend.batch, &backend);
    }
    try t.expectEqual(@as(u32, 25600), c.finished);
    try t.expectEqual(@as(u32, 256), pool.free_len);
}

test "exhaustion is an error, not a crash" {
    try setup();
    var parking = Parking{};
    const sc = efx.Scope.init(.{.{ Store, &parking }});
    var c = Ctx{ .sc = &sc };
    pool.user = &c;
    for (0..256) |i| try pool.spawn(task, i);
    try t.expectError(error.PoolExhausted, pool.spawn(task, 0));
    pool.cancel();
    try pool.spawn(task, 0);
    pool.cancel();
}
