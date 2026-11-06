//! Clock effect example — wall clock in production, virtual time in tests.
const std = @import("std");
const efx = @import("efx");

// ── Effect definition ────────────────────────────────────────────────

pub const Clock = efx.Effect(union(enum) {
    timestamp_ms: efx.Op(void, i64),
    sleep_ms: efx.Op(u64, std.Io.Cancelable!void),
});

// ── Handlers ─────────────────────────────────────────────────────────

pub const SystemHandler = struct {
    io: std.Io,

    pub fn timestamp_ms(self: *SystemHandler) i64 {
        return std.Io.Clock.Timestamp.now(self.io, .real).raw.toMilliseconds();
    }

    pub fn sleep_ms(self: *SystemHandler, ms: u64) std.Io.Cancelable!void {
        const duration: std.Io.Duration = .fromMilliseconds(@intCast(ms));
        return self.io.sleep(duration, .awake);
    }
};

pub const VirtualHandler = struct {
    now_ms: i64 = 0,

    pub fn timestamp_ms(self: *VirtualHandler) i64 {
        return self.now_ms;
    }

    pub fn sleep_ms(self: *VirtualHandler, ms: u64) std.Io.Cancelable!void {
        self.now_ms += @intCast(ms);
    }
};

// ── Business logic ───────────────────────────────────────────────────

fn isExpired(sc: *const efx.Scope, issued_ms: i64, ttl_ms: i64) bool {
    const now = Clock.exec(sc, .timestamp_ms, {});
    return now - issued_ms >= ttl_ms;
}

fn waitUntil(sc: *const efx.Scope, deadline_ms: i64) std.Io.Cancelable!void {
    while (Clock.exec(sc, .timestamp_ms, {}) < deadline_ms) {
        try Clock.exec(sc, .sleep_ms, 100);
    }
}

// ── Main ─────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    var handler = SystemHandler{ .io = init.io };
    const sc = efx.Scope.init(.{.{ Clock, &handler }});

    const now = Clock.exec(&sc, .timestamp_ms, {});
    std.debug.print("current time: {d}ms\n", .{now});
    std.debug.print("expired (ttl=0): {}\n", .{isExpired(&sc, now, 0)});
    std.debug.print("expired (ttl=9999999): {}\n", .{isExpired(&sc, now, 9999999)});
}

// ── Tests: deterministic with virtual clock ──────────────────────────

test "isExpired with virtual clock" {
    var clock = VirtualHandler{ .now_ms = 1000 };
    const sc = efx.Scope.init(.{.{ Clock, &clock }});

    try std.testing.expect(isExpired(&sc, 500, 400));
    try std.testing.expect(!isExpired(&sc, 500, 600));
}

test "waitUntil advances virtual time" {
    var clock = VirtualHandler{ .now_ms = 0 };
    const sc = efx.Scope.init(.{.{ Clock, &clock }});

    try waitUntil(&sc, 500);

    try std.testing.expectEqual(@as(i64, 500), clock.now_ms);
}
