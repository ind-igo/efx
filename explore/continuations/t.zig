const std = @import("std");
const efx = @import("efx");
const co = @import("co.zig");
const Co = co.Co;
const t = std.testing;
const gpa = t.allocator;

// 1 ── efx business logic, unchanged, with a REAL generator: no second task, no queue, no Io.
const Sink = efx.Effect(union(enum) { emit: efx.Op(u64, error{Aborted}!void) });

fn squares(sc: *const efx.Scope, cleaned_up: *bool) error{Aborted}!void {
    defer cleaned_up.* = true;
    var n: u64 = 1;
    while (true) : (n += 1) try Sink.exec(sc, .emit, n * n);
}

const Gen = Co(u64, void, void);
const Yielding = struct {
    k: *Gen,
    pub fn emit(self: *Yielding, v: u64) error{Aborted}!void {
        return self.k.perform(v);
    }
};
const CollectN = struct {
    seen: [8]u64 = undefined,
    len: usize = 0,
    pub fn emit(self: *CollectN, v: u64) error{Aborted}!void {
        if (self.len == self.seen.len) return error.Aborted;
        self.seen[self.len] = v;
        self.len += 1;
    }
};

const GenArg = struct { cleaned_up: *bool };
fn genBody(k: *Gen, raw: *anyopaque) error{Aborted}!void {
    const a: *GenArg = @ptrCast(@alignCast(raw));
    var h = Yielding{ .k = k };
    const sc = efx.Scope.init(.{.{ Sink, &h }});
    return squares(&sc, a.cleaned_up);
}

test "plain efx handler, no fibers: same business logic" {
    var h = CollectN{};
    var cleaned = false;
    const sc = efx.Scope.init(.{.{ Sink, &h }});
    try t.expectError(error.Aborted, squares(&sc, &cleaned));
    try t.expectEqual(@as(u64, 64), h.seen[7]);
    try t.expect(cleaned);
}

test "infinite generator: consumer pulls 3 values, then abort runs the producer's defer" {
    var cleaned = false;
    var arg = GenArg{ .cleaned_up = &cleaned };
    var k = try Gen.init(genBody, &arg);
    defer k.deinit();

    var ev = k.start();
    var got: [3]u64 = undefined;
    for (&got, 0..) |*g, i| {
        g.* = ev.perform;
        if (i < 2) ev = k.@"resume"({});
    }
    try t.expectEqualSlices(u64, &.{ 1, 4, 9 }, &got);
    try t.expect(!cleaned); // suspended mid-loop, the stack is alive
    ev = k.abort();
    try t.expect(cleaned);
    try t.expectError(error.Aborted, ev.done);
}

// 2 ── Code AFTER resume: the handler wraps the rest of the computation.
const Log = Co(u8, void, void);
fn logBody(k: *Log, _: *anyopaque) error{Aborted}!void {
    for ("abc") |c| try k.perform(c);
}
fn handleReversed(k: *Log, ev: Log.Event, out: *std.ArrayList(u8)) !void {
    switch (ev) {
        .done => |r| try r,
        .perform => |c| {
            try handleReversed(k, k.@"resume"({}), out); // the whole remaining program runs here
            try out.append(gpa, c); // ...and this runs after it
        },
    }
}
test "handler code runs after the continuation finishes" {
    var dummy: u8 = 0;
    var k = try Log.init(logBody, &dummy);
    defer k.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try handleReversed(&k, k.start(), &out);
    try t.expectEqualStrings("cba", out.items);
}

// 3 ── Continuations as values: a deterministic scheduler in the handler. No threads, no Io.
const Task = Co(void, void, void);
const Shared = struct { value: u32 = 0 };
fn racyIncrement(k: *Task, raw: *anyopaque) error{Aborted}!void {
    const s: *Shared = @ptrCast(@alignCast(raw));
    for (0..3) |_| {
        const v = s.value;
        try k.perform({}); // a preemption point inside read-modify-write
        s.value = v + 1;
        try k.perform({});
    }
}
fn simulate(seed: u64, order: []u8) !u32 {
    var s = Shared{};
    var tasks = [_]Task{ try .init(racyIncrement, &s), try .init(racyIncrement, &s) };
    defer for (&tasks) |*k| k.deinit();
    var started = [_]bool{ false, false };
    var live = [_]bool{ true, true };
    var rng = std.Random.DefaultPrng.init(seed);
    var n: usize = 0;
    while (live[0] or live[1]) {
        var i = rng.random().uintLessThan(u8, 2);
        if (!live[i]) i = 1 - i;
        if (n < order.len) order[n] = i;
        n += 1;
        const ev = if (started[i]) tasks[i].@"resume"({}) else tasks[i].start();
        started[i] = true;
        if (ev == .done) live[i] = false;
    }
    return s.value;
}
test "seed sweep finds a lost update, and that seed replays exactly" {
    var buggy: ?u64 = null;
    var outcomes: [8]bool = @splat(false);
    for (0..2000) |seed| {
        var order: [32]u8 = undefined;
        const v = try simulate(seed, &order);
        outcomes[v] = true;
        if (v < 6 and buggy == null) buggy = seed;
    }
    try t.expect(outcomes[6]); // correct interleavings exist
    const seed = buggy.?;
    var a: [32]u8 = @splat(9);
    var b: [32]u8 = @splat(9);
    const va = try simulate(seed, &a);
    const vb = try simulate(seed, &b);
    try t.expectEqual(va, vb);
    try t.expectEqualSlices(u8, &a, &b);
    try t.expect(va < 6);
}

// 4 ── Multi-shot: `choose` returns true AND false. Every path through the program.
const Amb = Co(void, bool, u8);
const AmbArg = struct { defers: *u32 };
fn ambBody(k: *Amb, raw: *anyopaque) error{Aborted}!u8 {
    const a: *AmbArg = @ptrCast(@alignCast(raw));
    defer a.defers.* += 1;
    var total: u8 = 0;
    const local = &total; // a pointer INTO the copied stack
    if (try k.perform({})) local.* += 1;
    if (try k.perform({})) local.* += 2;
    return total;
}
fn explore(k: *Amb, ev: Amb.Event, out: *std.ArrayList(u8)) !void {
    switch (ev) {
        .done => |r| try out.append(gpa, try r),
        .perform => {
            const snap = try k.snapshot(gpa);
            defer gpa.free(snap.bytes);
            try explore(k, k.@"resume"(true), out);
            k.restore(snap);
            try explore(k, k.@"resume"(false), out);
        },
    }
}
test "multi-shot explores all paths, with stack pointers intact" {
    var defers: u32 = 0;
    var arg = AmbArg{ .defers = &defers };
    var k = try Amb.init(ambBody, &arg);
    defer k.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try explore(&k, k.start(), &out);
    try t.expectEqualSlices(u8, &.{ 3, 1, 2, 0 }, out.items);
    // The catch: one `defer` in the source ran four times. A close() or free() there is a double free.
    try t.expectEqual(@as(u32, 4), defers);
}

// 5 ── Does it live alongside std.Io?
const IoCo = Co(void, void, void);
const IoArg = struct { io: std.Io, slept: bool = false };
fn ioBody(k: *IoCo, raw: *anyopaque) error{Aborted}!void {
    const a: *IoArg = @ptrCast(@alignCast(raw));
    a.io.sleep(.fromMilliseconds(5), .awake) catch {};
    try k.perform({});
    a.io.sleep(.fromMilliseconds(5), .awake) catch {};
    a.slept = true;
}
test "Threaded Io calls work from inside an effect fiber" {
    var a = IoArg{ .io = t.io };
    var k = try IoCo.init(ioBody, &a);
    defer k.deinit();
    _ = k.start();
    try t.expect(k.@"resume"({}) == .done);
    try t.expect(a.slept);
}
