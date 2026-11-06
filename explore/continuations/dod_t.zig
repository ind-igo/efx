const std = @import("std");
const efx = @import("efx");
const Pool = @import("dod.zig").Pool;
const t = std.testing;

// The business logic: one effect, no idea whether it parks.
const Store = efx.Effect(union(enum) { get: efx.Op(u64, error{Aborted}!u64) });

fn chase(sc: *const efx.Scope, start: u64, hops: u32) error{Aborted}!u64 {
    var k = start;
    for (0..hops) |_| k = try Store.exec(sc, .get, k);
    return k;
}

fn next(k: u64) u64 {
    return (k *% 2654435761 +% 1) % 1009;
}

const P = Pool(4096, 64 * 1024);
var pool: P = undefined;

const PlainStore = struct {
    pub fn get(_: *PlainStore, k: u64) error{Aborted}!u64 {
        return next(k);
    }
};
const ParkingStore = struct {
    p: *P,
    pub fn get(self: *ParkingStore, k: u64) error{Aborted}!u64 {
        return self.p.perform(k);
    }
};

const Ctx = struct {
    sc: *const efx.Scope,
    hops: u32,
    results: []u64,
    defers: u32 = 0,
    finished: u32 = 0,
};

fn task(p: *P, input: u64) void {
    const c: *Ctx = @ptrCast(@alignCast(p.user));
    defer c.defers += 1;
    c.results[input] = chase(c.sc, input, c.hops) catch return;
    c.finished += 1;
}

const Backend = struct {
    calls: u32 = 0,
    rows: u32 = 0,
    log_keys: ?*std.ArrayList(u64) = null,
    log_vals: ?*std.ArrayList(u64) = null,

    fn batch(raw: *anyopaque, keys: []const u64, out: []u64) void {
        const self: *Backend = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.rows += @intCast(keys.len);
        for (keys, out) |k, *o| o.* = next(k);
        if (self.log_keys) |l| l.appendSlice(t.allocator, keys) catch unreachable;
        if (self.log_vals) |l| l.appendSlice(t.allocator, out) catch unreachable;
    }
};

const Replay = struct {
    keys: []const u64,
    vals: []const u64,
    pos: usize = 0,

    fn batch(raw: *anyopaque, keys: []const u64, out: []u64) void {
        const self: *Replay = @ptrCast(@alignCast(raw));
        for (keys, out) |k, *o| {
            std.debug.assert(self.keys[self.pos] == k); // divergence would trip here
            o.* = self.vals[self.pos];
            self.pos += 1;
        }
    }
};

fn setup(c: *Ctx, h: *ParkingStore) !efx.Scope {
    try pool.init(c);
    h.* = .{ .p = &pool };
    return efx.Scope.init(.{.{ Store, h }});
}

test "same business logic: direct call, and parked on the pool" {
    var plain = PlainStore{};
    const direct = efx.Scope.init(.{.{ Store, &plain }});
    const want = try chase(&direct, 7, 25);

    var results: [8]u64 = undefined;
    var c = Ctx{ .sc = undefined, .hops = 25, .results = &results };
    var h: ParkingStore = undefined;
    const sc = try setup(&c, &h);
    defer pool.deinit();
    c.sc = &sc;
    try pool.spawn(task, 7);
    var b = Backend{};
    pool.run(Backend.batch, &b);
    try t.expectEqual(want, results[7]);
}

test "1000 tasks of 10 hops: 10 handler calls, not 10000, one shared scope" {
    var results: [1000]u64 = undefined;
    var c = Ctx{ .sc = undefined, .hops = 10, .results = &results };
    var h: ParkingStore = undefined;
    const sc = try setup(&c, &h);
    defer pool.deinit();
    c.sc = &sc;
    for (0..1000) |i| try pool.spawn(task, i);
    var b = Backend{};
    pool.run(Backend.batch, &b);
    try t.expectEqual(@as(u32, 10), b.calls);
    try t.expectEqual(@as(u32, 10000), b.rows);
    try t.expectEqual(@as(u32, 1000), c.finished);
    var plain = PlainStore{};
    const direct = efx.Scope.init(.{.{ Store, &plain }});
    for (results, 0..) |r, i| try t.expectEqual(try chase(&direct, i, 10), r);
}

test "replay: flat columns reproduce a run with no backend" {
    var keys: std.ArrayList(u64) = .empty;
    var vals: std.ArrayList(u64) = .empty;
    defer keys.deinit(t.allocator);
    defer vals.deinit(t.allocator);

    var first: [100]u64 = undefined;
    var c = Ctx{ .sc = undefined, .hops = 6, .results = &first };
    var h: ParkingStore = undefined;
    var sc = try setup(&c, &h);
    c.sc = &sc;
    for (0..100) |i| try pool.spawn(task, i);
    var b = Backend{ .log_keys = &keys, .log_vals = &vals };
    pool.run(Backend.batch, &b);
    pool.deinit();

    var second: [100]u64 = undefined;
    c = .{ .sc = undefined, .hops = 6, .results = &second };
    sc = try setup(&c, &h);
    defer pool.deinit();
    c.sc = &sc;
    for (0..100) |i| try pool.spawn(task, i);
    var r = Replay{ .keys = keys.items, .vals = vals.items };
    pool.run(Replay.batch, &r);
    try t.expectEqualSlices(u64, &first, &second);
    try t.expectEqual(keys.items.len, r.pos);
}

test "one-shot is enforced: a stale continuation is rejected" {
    var results: [4]u64 = undefined;
    var c = Ctx{ .sc = undefined, .hops = 1, .results = &results };
    var h: ParkingStore = undefined;
    const sc = try setup(&c, &h);
    defer pool.deinit();
    c.sc = &sc;
    try pool.spawn(task, 1);
    pool.tick();
    const k = pool.req_task[0];
    pool.req_len = 0;
    try pool.complete(k, 42);
    try t.expectError(error.StaleContinuation, pool.complete(k, 43));
    try t.expectError(error.StaleContinuation, pool.abort(k));
    pool.tick();
    try t.expectEqual(@as(u64, 42), results[1]);
}

test "abort: parked tasks unwind, defers run, every slot is recycled" {
    var results: [64]u64 = undefined;
    var c = Ctx{ .sc = undefined, .hops = 1000, .results = &results };
    var h: ParkingStore = undefined;
    const sc = try setup(&c, &h);
    defer pool.deinit();
    c.sc = &sc;
    const before = pool.free_len;
    for (0..64) |i| try pool.spawn(task, i);
    pool.tick();
    try t.expectEqual(@as(usize, 64), pool.pending().len);
    for (pool.req_task[0..pool.req_len]) |k| try pool.abort(k);
    pool.req_len = 0;
    pool.tick();
    try t.expectEqual(@as(u32, 64), c.defers);
    try t.expectEqual(@as(u32, 0), c.finished);
    try t.expectEqual(before, pool.free_len);
}

test "stacks recycle: 100x capacity through a bounded pool" {
    var results: [1]u64 = undefined;
    var c = Ctx{ .sc = undefined, .hops = 0, .results = &results };
    var h: ParkingStore = undefined;
    const sc = try setup(&c, &h);
    defer pool.deinit();
    c.sc = &sc;
    var b = Backend{};
    for (0..4096 * 100) |_| {
        try pool.spawn(task, 0);
        pool.run(Backend.batch, &b);
    }
    try t.expectEqual(@as(u32, 4096 * 100), c.finished);
}

test "exhaustion is an error, not a crash" {
    var results: [1]u64 = undefined;
    var c = Ctx{ .sc = undefined, .hops = 0, .results = &results };
    var h: ParkingStore = undefined;
    const sc = try setup(&c, &h);
    defer pool.deinit();
    c.sc = &sc;
    for (0..4096) |_| try pool.spawn(task, 0);
    try t.expectError(error.PoolExhausted, pool.spawn(task, 0));
    var b = Backend{};
    pool.run(Backend.batch, &b);
}
