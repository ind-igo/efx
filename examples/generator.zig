//! A handler that blocks on `std.Io.Queue` turns a plain effect into a stream.
//! The caller waits inside `exec` until a producer delivers the next item, so
//! this is ordinary blocking: the handler never holds a continuation, and it
//! returns to its caller like any other. Call sites are identical for the pure
//! array-backed handler and the blocking stream-backed handler.
//!
//! A single `next` op is just an interface, and for plain iteration an
//! `anytype` iterator is simpler. The effect earns its place when a call stack
//! that already carries a scope needs a source that may block.
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

/// Io-backed — `getOne` blocks the calling task until a producer puts an item.
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

// ── Tests ───────────────────────────────────────────────────────────

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

test "sumAll suspends on a stream fed by a concurrent producer" {
    const io = std.testing.io;
    var buffer: [4]u64 = undefined;
    var queue = std.Io.Queue(u64).init(&buffer);
    var producer = try io.concurrent(produce, .{ io, &queue });
    defer producer.await(io);

    var stream = StreamSource{ .io = io, .queue = &queue };
    const sc = efx.Scope.init(.{.{ Source, &stream }});
    try std.testing.expectEqual(@as(u64, 55), try sumAll(&sc));
}
