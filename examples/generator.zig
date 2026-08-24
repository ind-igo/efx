/// One-shot suspension by composition — a handler that blocks on
/// `std.Io.Queue` turns a plain tail-resumptive effect into a generator.
/// The caller's coroutine stack is the continuation; efx needs nothing
/// beyond ordinary dispatch. Call sites are identical for the pure
/// array-backed handler and the suspending stream-backed handler.
const std = @import("std");
const efx = @import("efx");

// ── Effect ──────────────────────────────────────────────────────────

const Source = efx.Effect(union(enum) {
    next: efx.Op(void, std.Io.Cancelable!?u64),
});

// ── Business logic — has no idea where items come from ──────────────

fn sumAll(sc: *const efx.Scope) std.Io.Cancelable!u64 {
    var total: u64 = 0;
    while (try Source.exec(sc, .next, {})) |item| total += item;
    return total;
}

// ── Handlers ────────────────────────────────────────────────────────

/// Pure, synchronous — this is also the test mock.
const ArraySource = struct {
    items: []const u64,
    i: usize = 0,

    pub fn next(self: *ArraySource) std.Io.Cancelable!?u64 {
        if (self.i >= self.items.len) return null;
        defer self.i += 1;
        return self.items[self.i];
    }
};

/// Io-backed — `getOne` suspends the calling coroutine until a producer
/// puts an item. From the caller's perspective this is a one-shot effect:
/// perform, suspend, resume with a value.
const StreamSource = struct {
    io: std.Io,
    queue: *std.Io.Queue(u64),

    pub fn next(self: *StreamSource) std.Io.Cancelable!?u64 {
        return self.queue.getOne(self.io) catch |e| switch (e) {
            error.Closed => null, // clean end of stream
            error.Canceled => error.Canceled, // cancellation must propagate
        };
    }
};

fn produce(io: std.Io, queue: *std.Io.Queue(u64)) void {
    defer queue.close(io); // always close, or the consumer suspends forever
    for (1..11) |n| queue.putOne(io, n) catch return;
}

// ── Main ────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Same business logic, pure handler.
    var arr = ArraySource{ .items = &.{ 1, 2, 3, 4, 5 } };
    const sc_array = efx.Scope.init(.{.{ Source, &arr }});
    std.debug.print("array sum:  {d}\n", .{try sumAll(&sc_array)});

    // Same business logic, suspending handler fed by a concurrent producer.
    var buffer: [4]u64 = undefined;
    var queue = std.Io.Queue(u64).init(&buffer);
    var producer = try io.concurrent(produce, .{ io, &queue });
    defer producer.await(io);

    var stream = StreamSource{ .io = io, .queue = &queue };
    const sc_stream = efx.Scope.init(.{.{ Source, &stream }});
    std.debug.print("stream sum: {d}\n", .{try sumAll(&sc_stream)});
}

// ── Tests: deterministic, no Io required ────────────────────────────

test "sumAll drains the source" {
    var arr = ArraySource{ .items = &.{ 10, 20, 30 } };
    const sc = efx.Scope.init(.{.{ Source, &arr }});
    try std.testing.expectEqual(@as(u64, 60), try sumAll(&sc));
}

test "empty source yields zero" {
    var arr = ArraySource{ .items = &.{} };
    const sc = efx.Scope.init(.{.{ Source, &arr }});
    try std.testing.expectEqual(@as(u64, 0), try sumAll(&sc));
}
