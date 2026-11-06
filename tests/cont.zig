//! Stack switching can break only once registers are allocated across it, which
//! Debug never does, so these run in every optimize mode.
const std = @import("std");
const efx = @import("efx");
const cont = @import("efx_cont");
const t = std.testing;

const Cancelable = cont.Cancelable;

// The business logic: one effect, no idea whether it parks.
const Store = efx.Effect(union(enum) { get: efx.Op(u64, Cancelable!u64) });

fn chase(sc: *const efx.Scope, start: u64, hops: u32) Cancelable!u64 {
    var k = start;
    for (0..hops) |_| k = try Store.exec(sc, .get, k);
    return k;
}

fn next(k: u64) u64 {
    return (k *% 2654435761 +% 1) % 1009;
}

const P = cont.Pool(.{ .Request = u64, .Reply = u64, .capacity = 512 });

const PlainStore = struct {
    pub fn get(_: *PlainStore, k: u64) Cancelable!u64 {
        return next(k);
    }
};
const ParkingStore = struct {
    pool: *P,
    pub fn get(self: *ParkingStore, k: u64) Cancelable!u64 {
        return self.pool.perform(k);
    }
};

/// Counts batches, like a backend that issues one call per batch.
fn drive(pool: *P) !u32 {
    var batches: u32 = 0;
    while (pool.live() != 0) {
        pool.tick();
        const batch = pool.take();
        if (batch.requests.len != 0) batches += 1;
        for (batch.requests, batch.conts) |r, k| try pool.complete(k, next(r));
    }
    return batches;
}

const Tally = struct { defers: u32 = 0, finished: u32 = 0 };

fn task(sc: *const efx.Scope, start: u64, hops: u32, out: *u64, tally: *Tally) void {
    defer tally.defers += 1;
    out.* = chase(sc, start, hops) catch return;
    tally.finished += 1;
}

fn newPool() !*P {
    const pool = try t.allocator.create(P);
    errdefer t.allocator.destroy(pool);
    try pool.init();
    return pool;
}

fn freePool(pool: *P) void {
    pool.deinit();
    t.allocator.destroy(pool);
}

test "the same business logic runs direct and parked" {
    var plain = PlainStore{};
    const direct = efx.Scope.init(.{.{ Store, &plain }});
    const want = try chase(&direct, 7, 25);

    const pool = try newPool();
    defer freePool(pool);
    var h = ParkingStore{ .pool = pool };
    const sc = efx.Scope.init(.{.{ Store, &h }});
    var got: u64 = 0;
    var tally = Tally{};
    try pool.spawn(task, .{ &sc, 7, 25, &got, &tally });
    _ = try drive(pool);
    try t.expectEqual(want, got);
}

test "400 tasks of 10 hops make 10 batches" {
    const pool = try newPool();
    defer freePool(pool);
    var h = ParkingStore{ .pool = pool };
    const sc = efx.Scope.init(.{.{ Store, &h }});
    var results: [400]u64 = undefined;
    var tally = Tally{};
    for (&results, 0..) |*r, i| try pool.spawn(task, .{ &sc, i, 10, r, &tally });
    try t.expectEqual(@as(u32, 10), try drive(pool));
    try t.expectEqual(@as(u32, 400), tally.finished);
    var plain = PlainStore{};
    const direct = efx.Scope.init(.{.{ Store, &plain }});
    for (results, 0..) |r, i| try t.expectEqual(try chase(&direct, i, 10), r);
}

test "a held continuation resumes later, out of order, with handler code around it" {
    const Timers = struct {
        pool: *P,
        held: [3]cont.Cont = undefined,
        n: usize = 0,
        pub fn get(self: *@This(), k: u64) Cancelable!u64 {
            self.held[self.n] = self.pool.continuation();
            self.n += 1;
            const reply = try self.pool.park();
            return reply + k;
        }
    };
    const pool = try newPool();
    defer freePool(pool);
    var h = Timers{ .pool = pool };
    const sc = efx.Scope.init(.{.{ Store, &h }});
    var results: [3]u64 = undefined;
    var tally = Tally{};
    for (&results, 0..) |*r, i| try pool.spawn(task, .{ &sc, i, 1, r, &tally });

    pool.tick();
    try t.expectEqual(@as(usize, 3), h.n);
    try t.expectEqual(@as(usize, 0), pool.take().requests.len);
    // Nothing is ready, and nothing moves until the handler says so.
    pool.tick();
    try t.expectEqual(@as(u32, 0), tally.finished);

    try pool.complete(h.held[2], 100);
    pool.tick();
    try t.expectEqual(@as(u32, 1), tally.finished);
    try pool.complete(h.held[0], 200);
    try pool.complete(h.held[1], 300);
    pool.tick();
    try t.expectEqualSlices(u64, &.{ 200, 301, 102 }, &results);
    try t.expectEqual(@as(usize, 0), pool.live());
}

test "a resume is one-shot" {
    const pool = try newPool();
    defer freePool(pool);
    var h = ParkingStore{ .pool = pool };
    const sc = efx.Scope.init(.{.{ Store, &h }});
    var got: u64 = 0;
    var tally = Tally{};
    try pool.spawn(task, .{ &sc, 1, 1, &got, &tally });
    pool.tick();
    const k = pool.take().conts[0];
    try pool.complete(k, 42);
    try t.expectError(error.StaleContinuation, pool.complete(k, 43));
    try t.expectError(error.StaleContinuation, pool.cancel(k));
    pool.tick();
    try t.expectEqual(@as(u64, 42), got);
}

test "a stale handle stays stale after 70000 resumes of its slot" {
    const pool = try newPool();
    defer freePool(pool);
    var h = ParkingStore{ .pool = pool };
    const sc = efx.Scope.init(.{.{ Store, &h }});
    var got: u64 = 0;
    var tally = Tally{};
    try pool.spawn(task, .{ &sc, 1, 70_001, &got, &tally });
    pool.tick();
    const stale = pool.take().conts[0];
    try pool.complete(stale, 1);
    for (0..70_000) |_| {
        pool.tick();
        const k = pool.take().conts[0];
        try t.expectError(error.StaleContinuation, pool.complete(stale, 0));
        try pool.complete(k, 1);
    }
    pool.tick();
    try t.expectEqual(@as(u32, 1), tally.finished);
}

test "cancel unwinds parked tasks, runs defers and frees every slot" {
    const pool = try newPool();
    defer freePool(pool);
    var h = ParkingStore{ .pool = pool };
    const sc = efx.Scope.init(.{.{ Store, &h }});
    var results: [64]u64 = undefined;
    var tally = Tally{};
    for (&results, 0..) |*r, i| try pool.spawn(task, .{ &sc, i, 1000, r, &tally });
    pool.tick();
    const batch = pool.take();
    try t.expectEqual(@as(usize, 64), batch.conts.len);
    for (batch.conts) |k| try pool.cancel(k);
    pool.tick();
    try t.expectEqual(@as(u32, 64), tally.defers);
    try t.expectEqual(@as(u32, 0), tally.finished);
    try t.expectEqual(@as(usize, 0), pool.live());
}

test "deinit cancels what is parked, including held continuations" {
    const Holder = struct {
        pool: *P,
        held: ?cont.Cont = null,
        pub fn get(self: *@This(), _: u64) Cancelable!u64 {
            self.held = self.pool.continuation();
            return self.pool.park();
        }
    };
    var tally = Tally{};
    var results: [32]u64 = undefined;
    const pool = try newPool();
    var h = Holder{ .pool = pool };
    const sc = efx.Scope.init(.{.{ Store, &h }});
    for (&results, 0..) |*r, i| try pool.spawn(task, .{ &sc, i, 5, r, &tally });
    pool.tick();
    // Some never ran: queued, not parked.
    try pool.spawn(task, .{ &sc, 0, 5, &results[0], &tally });
    try t.expectEqual(@as(usize, 33), pool.live());
    freePool(pool);
    try t.expectEqual(@as(u32, 33), tally.defers);
    try t.expectEqual(@as(u32, 0), tally.finished);
}

test "cancelAll leaves held handles stale" {
    const pool = try newPool();
    defer freePool(pool);
    var h = ParkingStore{ .pool = pool };
    const sc = efx.Scope.init(.{.{ Store, &h }});
    var got: u64 = 0;
    var tally = Tally{};
    try pool.spawn(task, .{ &sc, 1, 5, &got, &tally });
    pool.tick();
    const k = pool.take().conts[0];
    pool.cancelAll();
    try t.expectError(error.StaleContinuation, pool.complete(k, 1));
    try t.expectEqual(@as(usize, 0), pool.live());
}

test "a perform inside a defer during cancelAll gets Canceled" {
    const S = struct {
        var cleanup: ?Cancelable!u64 = null;
        fn body(pool: *P) Cancelable!void {
            defer cleanup = pool.perform(9);
            _ = try pool.perform(1);
        }
    };
    const pool = try newPool();
    defer freePool(pool);
    try pool.spawn(S.body, .{pool});
    pool.tick();
    pool.cancelAll();
    try t.expectError(error.Canceled, S.cleanup.?);
}

test "cancelAll waits for a fiber woken by another, instead of resuming it twice" {
    const S = struct {
        var woken: u32 = 0;
        fn waiter(pool: *P, out: *cont.Cont) void {
            out.* = pool.continuation();
            _ = pool.park() catch {};
            woken += 1;
        }
        fn waker(pool: *P, k: *cont.Cont) void {
            _ = pool.perform(0) catch {};
            pool.complete(k.*, 1) catch {};
        }
    };
    const pool = try newPool();
    defer freePool(pool);
    var k: cont.Cont = undefined;
    try pool.spawn(S.waiter, .{ pool, &k });
    try pool.spawn(S.waker, .{ pool, &k });
    pool.tick();
    try pool.complete(pool.take().conts[0], 0);
    // cancelAll's own tick runs the waker, which queues the waiter. Cancelling
    // the waiter as well would put it on the queue twice.
    pool.cancelAll();
    try t.expectEqual(@as(u32, 1), S.woken);
    try t.expectEqual(@as(usize, 0), pool.live());
}

test "a canceled slot works normally when it is reused" {
    const pool = try newPool();
    defer freePool(pool);
    var h = ParkingStore{ .pool = pool };
    const sc = efx.Scope.init(.{.{ Store, &h }});
    var got: u64 = 0;
    var tally = Tally{};
    try pool.spawn(task, .{ &sc, 1, 3, &got, &tally });
    pool.tick();
    try pool.cancel(pool.take().conts[0]);
    pool.tick();
    try t.expectEqual(@as(u32, 0), tally.finished);

    try pool.spawn(task, .{ &sc, 1, 3, &got, &tally });
    _ = try drive(pool);
    try t.expectEqual(@as(u32, 1), tally.finished);
}

test "work queued during a tick waits for the next one, and none is lost" {
    const S = struct {
        var parents: u32 = 0;
        var children: u32 = 0;
        fn child() void {
            children += 1;
        }
        fn parent(pool: *P) void {
            parents += 1;
            pool.spawn(child, .{}) catch unreachable;
            pool.spawn(child, .{}) catch unreachable;
        }
    };
    const pool = try newPool();
    defer freePool(pool);
    for (0..4) |_| try pool.spawn(S.parent, .{pool});
    pool.tick();
    try t.expectEqual(@as(u32, 4), S.parents);
    try t.expectEqual(@as(u32, 0), S.children);
    pool.tick();
    try t.expectEqual(@as(u32, 8), S.children);
}

test "a computation can return Canceled" {
    const S = struct {
        fn body(pool: *P, ran: *bool) Cancelable!void {
            defer ran.* = true;
            _ = try pool.perform(1);
        }
    };
    const pool = try newPool();
    defer freePool(pool);
    var ran = false;
    try pool.spawn(S.body, .{ pool, &ran });
    pool.tick();
    try pool.cancel(pool.take().conts[0]);
    pool.tick();
    try t.expect(ran);
    try t.expectEqual(@as(usize, 0), pool.live());
}

test "tasks spawn tasks, and resume each other" {
    const S = struct {
        var woken: u64 = 0;
        fn child(pool: *P, waiting: cont.Cont) void {
            pool.complete(waiting, 7) catch unreachable;
        }
        fn parent(pool: *P) void {
            pool.spawn(child, .{ pool, pool.continuation() }) catch unreachable;
            woken = pool.park() catch unreachable;
        }
    };
    const pool = try newPool();
    defer freePool(pool);
    try pool.spawn(S.parent, .{pool});
    while (pool.live() != 0) pool.tick();
    try t.expectEqual(@as(u64, 7), S.woken);
}

test "typed requests and replies" {
    const Disk = union(enum) { read: u32, write: struct { at: u32, bytes: []const u8 } };
    const Reply = union(enum) { bytes: []const u8, written: usize };
    const Q = cont.Pool(.{ .Request = Disk, .Reply = Reply, .capacity = 4 });
    const S = struct {
        fn body(pool: *Q, out: *usize) Cancelable!void {
            const w = try pool.perform(.{ .write = .{ .at = 3, .bytes = "abcd" } });
            const r = try pool.perform(.{ .read = 3 });
            out.* = w.written + r.bytes.len;
        }
    };
    const pool = try t.allocator.create(Q);
    defer t.allocator.destroy(pool);
    try pool.init();
    defer pool.deinit();
    var out: usize = 0;
    try pool.spawn(S.body, .{ pool, &out });
    while (pool.live() != 0) {
        pool.tick();
        const batch = pool.take();
        for (batch.requests, batch.conts) |request, k| try pool.complete(k, switch (request) {
            .read => .{ .bytes = "hello" },
            .write => |w| .{ .written = w.bytes.len },
        });
    }
    try t.expectEqual(@as(usize, 9), out);
}

test "arguments keep their alignment" {
    const Wide = struct { v: u64 align(256) };
    const S = struct {
        fn body(a: u8, w: Wide, out: *u64) void {
            out.* = a + w.v + @as(u64, @intFromBool(@intFromPtr(&w) % 256 == 0));
        }
    };
    const pool = try newPool();
    defer freePool(pool);
    var out: [2]u64 = undefined;
    // Slot 0 has no colour offset, so it would be aligned by luck.
    for (&out) |*o| try pool.spawn(S.body, .{ 1, Wide{ .v = 10 }, o });
    pool.tick();
    try t.expectEqualSlices(u64, &.{ 12, 12 }, &out);
}

test "stacks recycle through 100x capacity" {
    const pool = try newPool();
    defer freePool(pool);
    var h = ParkingStore{ .pool = pool };
    const sc = efx.Scope.init(.{.{ Store, &h }});
    var got: u64 = 0;
    var tally = Tally{};
    for (0..51_200) |i| {
        try pool.spawn(task, .{ &sc, i, 2, &got, &tally });
        _ = try drive(pool);
    }
    try t.expectEqual(@as(u32, 51_200), tally.finished);
}

test "exhaustion is an error, not a crash" {
    const pool = try newPool();
    defer freePool(pool);
    var h = ParkingStore{ .pool = pool };
    const sc = efx.Scope.init(.{.{ Store, &h }});
    var got: u64 = 0;
    var tally = Tally{};
    for (0..512) |_| try pool.spawn(task, .{ &sc, 0, 0, &got, &tally });
    try t.expectError(error.PoolExhausted, pool.spawn(task, .{ &sc, 0, 0, &got, &tally }));
    _ = try drive(pool);
}

test "pools of one type run on separate threads" {
    const S = struct {
        fn worker(seed: u64, ok: *bool) void {
            run(seed, ok) catch {};
        }
        fn run(seed: u64, ok: *bool) !void {
            const pool = try std.heap.page_allocator.create(P);
            defer std.heap.page_allocator.destroy(pool);
            try pool.init();
            defer pool.deinit();
            var h = ParkingStore{ .pool = pool };
            const sc = efx.Scope.init(.{.{ Store, &h }});
            var results: [64]u64 = undefined;
            var tally = Tally{};
            for (&results, 0..) |*r, i| try pool.spawn(task, .{ &sc, seed + i, 2000, r, &tally });
            _ = try drive(pool);
            var plain = PlainStore{};
            const direct = efx.Scope.init(.{.{ Store, &plain }});
            for (results, 0..) |r, i| {
                if (r != try chase(&direct, seed + i, 2000)) return;
            }
            // Many short computations: a pool found through shared state would
            // start one of them on another thread's pool.
            for (0..200_000) |_| {
                try pool.spawn(task, .{ &sc, 0, 0, &results[0], &tally });
                pool.tick();
            }
            ok.* = tally.finished == 64 + 200_000;
        }
    };
    var ok: [4]bool = @splat(false);
    var threads: [4]std.Thread = undefined;
    // `Store`'s slot is assigned on first use, so bind it once here.
    _ = Store.ensureSlot();
    for (&threads, &ok, 0..) |*th, *o, i| th.* = try std.Thread.spawn(.{}, S.worker, .{ i * 1000, o });
    for (&threads) |th| th.join();
    try t.expectEqual(@as(usize, 4), std.mem.count(bool, &ok, &.{true}));
}
