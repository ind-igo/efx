/// Clock effect example — wall clock in production, virtual time in tests.
const std = @import("std");
const fx = @import("fx");

// ── Effect definition ────────────────────────────────────────────────

pub const Clock = fx.Effect(union(enum) {
    timestamp_ms: fx.Op(void, i64),
    sleep_ms: fx.Op(u64, void),
});

// ── Handlers ─────────────────────────────────────────────────────────

/// Real wall clock. In 0.16 time and sleep go through `std.Io`.
pub const SystemHandler = struct {
    io: std.Io,

    pub fn timestamp_ms(self: *SystemHandler) i64 {
        return std.Io.Clock.Timestamp.now(self.io, .real).raw.toMilliseconds();
    }

    pub fn sleep_ms(self: *SystemHandler, ms: u64) void {
        const duration: std.Io.Duration = .fromMilliseconds(@intCast(ms));
        self.io.sleep(duration, .awake) catch {};
    }
};

/// Virtual clock for deterministic testing. Time only advances via sleep.
pub const VirtualHandler = struct {
    now_ms: i64 = 0,

    pub fn timestamp_ms(self: *VirtualHandler) i64 {
        return self.now_ms;
    }

    pub fn sleep_ms(self: *VirtualHandler, ms: u64) void {
        self.now_ms += @intCast(ms);
    }
};

// ── Business logic ───────────────────────────────────────────────────

fn isExpired(issued_ms: i64, ttl_ms: i64) bool {
    const now = Clock.exec(.timestamp_ms, {});
    return now - issued_ms >= ttl_ms;
}

fn waitUntil(deadline_ms: i64) void {
    while (Clock.exec(.timestamp_ms, {}) < deadline_ms) {
        Clock.exec(.sleep_ms, 100);
    }
}

// ── Main ─────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    var handler = SystemHandler{ .io = init.io };
    fx.init(.{.{ Clock, &handler }});

    const now = Clock.exec(.timestamp_ms, {});
    std.debug.print("current time: {d}ms\n", .{now});
    std.debug.print("expired (ttl=0): {}\n", .{isExpired(now, 0)});
    std.debug.print("expired (ttl=9999999): {}\n", .{isExpired(now, 9999999)});
}

// ── Tests: deterministic with virtual clock ──────────────────────────

test "isExpired with virtual clock" {
    var clock = VirtualHandler{ .now_ms = 1000 };
    fx.init(.{.{ Clock, &clock }});

    try std.testing.expect(isExpired(500, 400));
    try std.testing.expect(!isExpired(500, 600));
}

test "waitUntil advances virtual time" {
    var clock = VirtualHandler{ .now_ms = 0 };
    fx.init(.{.{ Clock, &clock }});

    waitUntil(500);

    try std.testing.expectEqual(@as(i64, 500), clock.now_ms);
}
