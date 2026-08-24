/// Logger effect example — stderr, JSON, and test handlers for the same effect.
const std = @import("std");
const fx = @import("efx");

// ── Effect definition ────────────────────────────────────────────────

pub const Logger = fx.Effect(union(enum) {
    info: fx.Op([]const u8, void),
    warn: fx.Op([]const u8, void),
    err: fx.Op([]const u8, void),
});

// ── Handlers ─────────────────────────────────────────────────────────

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

pub const TestHandler = struct {
    buf: [64][]const u8 = undefined,
    len: usize = 0,

    fn push(self: *TestHandler, msg: []const u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = msg;
            self.len += 1;
        }
    }

    pub fn info(self: *TestHandler, msg: []const u8) void { self.push(msg); }
    pub fn warn(self: *TestHandler, msg: []const u8) void { self.push(msg); }
    pub fn err(self: *TestHandler, msg: []const u8) void { self.push(msg); }

    pub fn slice(self: *const TestHandler) []const []const u8 {
        return self.buf[0..self.len];
    }
};

// ── Business logic that uses the effect ──────────────────────────────

fn processOrder(sc: *const fx.Scope, order_id: []const u8) void {
    Logger.exec(sc, .info, order_id);
    Logger.exec(sc, .info, "order complete");
}

// ── Main: stderr handler, then scoped swap to JSON ───────────────────

pub fn main(_: std.process.Init) !void {
    var handler = StderrHandler{};
    const sc = fx.Scope.init(.{.{ Logger, &handler }});

    processOrder(&sc, "order_42");

    var json = JsonHandler{};
    const sc2 = sc.bind(Logger, &json);

    processOrder(&sc2, "order_43");
}

// ── Tests ────────────────────────────────────────────────────────────

test "processOrder logs order id" {
    var handler = TestHandler{};
    const sc = fx.Scope.init(.{.{ Logger, &handler }});

    processOrder(&sc, "order_99");

    try std.testing.expectEqual(@as(usize, 2), handler.len);
    try std.testing.expectEqualStrings("order_99", handler.slice()[0]);
    try std.testing.expectEqualStrings("order complete", handler.slice()[1]);
}
