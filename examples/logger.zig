/// Logger effect example — stderr, JSON, and test handlers for the same effect.
const std = @import("std");
const fx = @import("fx");

// ── Effect definition ────────────────────────────────────────────────

pub const Logger = fx.Effect(union(enum) {
    info: fx.Op([]const u8, void),
    warn: fx.Op([]const u8, void),
    err: fx.Op([]const u8, void),
});

// ── Handlers ─────────────────────────────────────────────────────────

/// Writes human-readable lines to stderr.
pub const StderrHandler = struct {
    pub fn info(_: *StderrHandler, msg: []const u8) void {
        std.debug.print("[INFO] {s}\n", .{msg});
    }

    pub fn warn(_: *StderrHandler, msg: []const u8) void {
        std.debug.print("[WARN] {s}\n", .{msg});
    }

    pub fn err(_: *StderrHandler, msg: []const u8) void {
        std.debug.print("[ERR ] {s}\n", .{msg});
    }
};

/// Writes JSON lines to stderr.
pub const JsonHandler = struct {
    pub fn info(_: *JsonHandler, msg: []const u8) void {
        std.debug.print("{{\"level\":\"info\",\"msg\":\"{s}\"}}\n", .{msg});
    }

    pub fn warn(_: *JsonHandler, msg: []const u8) void {
        std.debug.print("{{\"level\":\"warn\",\"msg\":\"{s}\"}}\n", .{msg});
    }

    pub fn err(_: *JsonHandler, msg: []const u8) void {
        std.debug.print("{{\"level\":\"err\",\"msg\":\"{s}\"}}\n", .{msg});
    }
};

/// Collects messages in-memory for test assertions.
pub const TestHandler = struct {
    buf: [64][]const u8 = undefined,
    len: usize = 0,

    fn push(self: *TestHandler, msg: []const u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = msg;
            self.len += 1;
        }
    }

    pub fn info(self: *TestHandler, msg: []const u8) void {
        self.push(msg);
    }

    pub fn warn(self: *TestHandler, msg: []const u8) void {
        self.push(msg);
    }

    pub fn err(self: *TestHandler, msg: []const u8) void {
        self.push(msg);
    }

    pub fn slice(self: *const TestHandler) []const []const u8 {
        return self.buf[0..self.len];
    }
};

// ── Business logic that uses the effect ──────────────────────────────

fn processOrder(order_id: []const u8) void {
    Logger.exec(.info, order_id);
    Logger.exec(.info, "order complete");
}

// ── Main: stderr handler, then scoped swap to JSON ───────────────────

pub fn main() !void {
    var handler = StderrHandler{};
    fx.init(.{.{ Logger, &handler }});

    processOrder("order_42");

    // Scoped swap to JSON
    var json = JsonHandler{};
    const token = fx.set(Logger, &json);
    defer fx.reset(token);

    processOrder("order_43");
}

// ── Tests ────────────────────────────────────────────────────────────

test "processOrder logs order id" {
    var handler = TestHandler{};
    fx.init(.{.{ Logger, &handler }});

    processOrder("order_99");

    try std.testing.expectEqual(@as(usize, 2), handler.len);
    try std.testing.expectEqualStrings("order_99", handler.slice()[0]);
    try std.testing.expectEqualStrings("order complete", handler.slice()[1]);
}
