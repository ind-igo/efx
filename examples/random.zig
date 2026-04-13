/// Random effect example — OS entropy in production, seeded PRNG in tests.
const std = @import("std");
const fx = @import("fx");

// ── Effect definition ────────────────────────────────────────────────

pub const Range = struct { min: u64, max: u64 };

pub const Random = fx.Effect(union(enum) {
    int_u64: fx.Op(void, u64),
    range: fx.Op(Range, u64),
    boolean: fx.Op(void, bool),
});

// ── Handlers ─────────────────────────────────────────────────────────

/// Backed by OS cryptographic randomness.
pub const SystemHandler = struct {
    pub fn int_u64(_: *SystemHandler) u64 {
        return std.crypto.random.int(u64);
    }

    pub fn range(_: *SystemHandler, r: Range) u64 {
        return std.crypto.random.intRangeAtMost(u64, r.min, r.max);
    }

    pub fn boolean(_: *SystemHandler) bool {
        return std.crypto.random.boolean();
    }
};

/// Seeded PRNG for deterministic testing.
pub const SeededHandler = struct {
    rng: std.Random.DefaultPrng,

    pub fn init(seed: u64) SeededHandler {
        return .{ .rng = std.Random.DefaultPrng.init(seed) };
    }

    pub fn int_u64(self: *SeededHandler) u64 {
        return self.rng.random().int(u64);
    }

    pub fn range(self: *SeededHandler, r: Range) u64 {
        return self.rng.random().intRangeAtMost(u64, r.min, r.max);
    }

    pub fn boolean(self: *SeededHandler) bool {
        return self.rng.random().boolean();
    }
};

// ── Business logic ───────────────────────────────────────────────────

fn pick(comptime T: type, items: []const T) T {
    const idx = Random.exec(.range, .{ .min = 0, .max = items.len - 1 });
    return items[idx];
}

fn rollDice() u64 {
    return Random.exec(.range, .{ .min = 1, .max = 6 });
}

// ── Main ─────────────────────────────────────────────────────────────

pub fn main() !void {
    var handler = SystemHandler{};
    fx.init(.{.{ Random, &handler }});

    const colors = [_][]const u8{ "red", "blue", "green", "yellow" };

    std.debug.print("random color: {s}\n", .{pick([]const u8, &colors)});
    std.debug.print("dice roll: {d}\n", .{rollDice()});
    std.debug.print("coin flip: {}\n", .{Random.exec(.boolean, {})});
}

// ── Tests: reproducible with seeded handler ──────────────────────────

test "seeded random is deterministic" {
    var rng1 = SeededHandler.init(42);
    fx.init(.{.{ Random, &rng1 }});

    const a = Random.exec(.int_u64, {});
    const b = Random.exec(.int_u64, {});

    var rng2 = SeededHandler.init(42);
    fx.init(.{.{ Random, &rng2 }});

    try std.testing.expectEqual(a, Random.exec(.int_u64, {}));
    try std.testing.expectEqual(b, Random.exec(.int_u64, {}));
}

test "pick is deterministic with seed" {
    var rng = SeededHandler.init(99);
    fx.init(.{.{ Random, &rng }});

    const colors = [_][]const u8{ "red", "blue", "green", "yellow" };
    const first = pick([]const u8, &colors);

    var rng2 = SeededHandler.init(99);
    fx.init(.{.{ Random, &rng2 }});

    try std.testing.expectEqualStrings(first, pick([]const u8, &colors));
}
