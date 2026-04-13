/// Data-processing pipeline — validate → enrich → store.
/// Four effects compose naturally; tests swap all handlers to deterministic versions.
const std = @import("std");
const fx = @import("fx");

// ── Effects ────────────────────────────────────────────────────────

const Logger = fx.Effect(union(enum) { info: fx.Op([]const u8, void), err: fx.Op([]const u8, void) });
const Metrics = fx.Effect(union(enum) { inc: fx.Op([]const u8, void), get: fx.Op([]const u8, u64) });
const Clock = fx.Effect(union(enum) { now_ms: fx.Op(void, i64) });
const FeatureFlags = fx.Effect(union(enum) { enabled: fx.Op([]const u8, bool) });

// ── Domain ─────────────────────────────────────────────────────────

const Record = struct { id: []const u8, email: []const u8, payload: []const u8, enriched_at: i64 = 0, stored_at: i64 = 0 };
const Result = struct { processed: u32 = 0, failed: u32 = 0, skipped: u32 = 0 };

// ── Pipeline stages ────────────────────────────────────────────────

fn validate(rec: *const Record) bool {
    if (rec.email.len == 0) {
        Logger.exec(.err, "missing email");
        Metrics.exec(.inc, "validate.fail");
        return false;
    }
    for (rec.email) |c| {
        if (c == '@') {
            Metrics.exec(.inc, "validate.pass");
            return true;
        }
    }
    Logger.exec(.err, "invalid email");
    Metrics.exec(.inc, "validate.fail");
    return false;
}

fn enrich(rec: *Record) void {
    if (!FeatureFlags.exec(.enabled, "enrichment")) {
        Logger.exec(.info, "enrichment skipped");
        return;
    }
    rec.enriched_at = Clock.exec(.now_ms, {});
    Metrics.exec(.inc, "enrich.ok");
}

fn store(rec: *Record) void {
    rec.stored_at = Clock.exec(.now_ms, {});
    Logger.exec(.info, "stored");
    Metrics.exec(.inc, "store.ok");
}

fn processBatch(records: []Record) Result {
    var r = Result{};
    Logger.exec(.info, "batch start");
    for (records) |*rec| {
        if (!validate(rec)) { r.failed += 1; continue; }
        enrich(rec);
        if (rec.enriched_at == 0 and FeatureFlags.exec(.enabled, "enrichment")) { r.skipped += 1; continue; }
        store(rec);
        r.processed += 1;
    }
    Logger.exec(.info, "batch end");
    return r;
}

// ── Test handlers ──────────────────────────────────────────────────

const TestLogger = struct {
    buf: [64][]const u8 = undefined,
    len: usize = 0,

    pub fn info(self: *TestLogger, msg: []const u8) void { self.push(msg); }
    pub fn err(self: *TestLogger, msg: []const u8) void { self.push(msg); }

    fn push(self: *TestLogger, msg: []const u8) void {
        if (self.len < self.buf.len) { self.buf[self.len] = msg; self.len += 1; }
    }
    fn has(self: *const TestLogger, needle: []const u8) bool {
        for (self.buf[0..self.len]) |m| if (std.mem.eql(u8, m, needle)) return true;
        return false;
    }
};

const CounterMap = struct {
    keys: [32][]const u8 = undefined,
    vals: [32]u64 = undefined,
    len: usize = 0,

    pub fn inc(self: *CounterMap, name: []const u8) void {
        for (self.keys[0..self.len], self.vals[0..self.len]) |k, *v|
            if (std.mem.eql(u8, k, name)) { v.* += 1; return; };
        if (self.len < self.keys.len) { self.keys[self.len] = name; self.vals[self.len] = 1; self.len += 1; }
    }
    pub fn get(self: *CounterMap, name: []const u8) u64 {
        for (self.keys[0..self.len], self.vals[0..self.len]) |k, v|
            if (std.mem.eql(u8, k, name)) return v;
        return 0;
    }
};

const TestClock = struct {
    time: i64 = 1000,
    pub fn now_ms(self: *TestClock) i64 { defer self.time += 10; return self.time; }
};

const TestFlags = struct {
    enrichment_on: bool = true,
    pub fn enabled(self: *TestFlags, name: []const u8) bool { return std.mem.eql(u8, name, "enrichment") and self.enrichment_on; }
};

// ── Tests ──────────────────────────────────────────────────────────

test "happy path: valid records are enriched and stored" {
    var log = TestLogger{};
    var met = CounterMap{};
    var clk = TestClock{};
    var flg = TestFlags{};
    fx.init(.{ .{ Logger, &log }, .{ Metrics, &met }, .{ Clock, &clk }, .{ FeatureFlags, &flg } });

    var recs = [_]Record{
        .{ .id = "1", .email = "a@b.com", .payload = "d1" },
        .{ .id = "2", .email = "c@d.org", .payload = "d2" },
    };
    const r = processBatch(&recs);

    try std.testing.expectEqual(@as(u32, 2), r.processed);
    try std.testing.expectEqual(@as(u32, 0), r.failed);
    try std.testing.expect(recs[0].enriched_at > 0);
    try std.testing.expect(recs[0].stored_at > recs[0].enriched_at);
    try std.testing.expectEqual(@as(u64, 2), met.get("validate.pass"));
    try std.testing.expectEqual(@as(u64, 2), met.get("store.ok"));
    try std.testing.expect(log.has("batch start"));
    try std.testing.expect(log.has("batch end"));
}

test "invalid records are rejected and counted" {
    var log = TestLogger{};
    var met = CounterMap{};
    var clk = TestClock{};
    var flg = TestFlags{};
    fx.init(.{ .{ Logger, &log }, .{ Metrics, &met }, .{ Clock, &clk }, .{ FeatureFlags, &flg } });

    var recs = [_]Record{
        .{ .id = "x", .email = "", .payload = "a" },
        .{ .id = "y", .email = "no-at", .payload = "b" },
        .{ .id = "z", .email = "ok@ok", .payload = "c" },
    };
    const r = processBatch(&recs);

    try std.testing.expectEqual(@as(u32, 1), r.processed);
    try std.testing.expectEqual(@as(u32, 2), r.failed);
    try std.testing.expectEqual(@as(u64, 2), met.get("validate.fail"));
    try std.testing.expectEqual(@as(u64, 1), met.get("validate.pass"));
}

test "feature flag disables enrichment" {
    var log = TestLogger{};
    var met = CounterMap{};
    var clk = TestClock{};
    var flg = TestFlags{ .enrichment_on = false };
    fx.init(.{ .{ Logger, &log }, .{ Metrics, &met }, .{ Clock, &clk }, .{ FeatureFlags, &flg } });

    var recs = [_]Record{.{ .id = "1", .email = "a@b.com", .payload = "d" }};
    const r = processBatch(&recs);

    try std.testing.expectEqual(@as(u32, 1), r.processed);
    try std.testing.expectEqual(@as(i64, 0), recs[0].enriched_at);
    try std.testing.expect(recs[0].stored_at > 0);
    try std.testing.expectEqual(@as(u64, 0), met.get("enrich.ok"));
    try std.testing.expect(log.has("enrichment skipped"));
}

test "scoped swap: silence logging for a batch section" {
    var log = TestLogger{};
    var met = CounterMap{};
    var clk = TestClock{};
    var flg = TestFlags{};
    fx.init(.{ .{ Logger, &log }, .{ Metrics, &met }, .{ Clock, &clk }, .{ FeatureFlags, &flg } });

    // Normal batch — logger captures messages
    var r1 = [_]Record{.{ .id = "1", .email = "a@b.com", .payload = "d" }};
    _ = processBatch(&r1);
    const before = log.len;
    try std.testing.expect(before > 0);

    // Swap to silent logger for a noisy section
    var silent = struct {
        pub fn info(_: *@This(), _: []const u8) void {}
        pub fn err(_: *@This(), _: []const u8) void {}
    }{};
    const token = fx.set(Logger, &silent);

    var r2 = [_]Record{.{ .id = "2", .email = "x@y.com", .payload = "d" }};
    _ = processBatch(&r2);
    try std.testing.expectEqual(before, log.len); // no growth

    // Restore — original logger active again
    fx.reset(token);

    var r3 = [_]Record{.{ .id = "3", .email = "z@w.com", .payload = "d" }};
    _ = processBatch(&r3);
    try std.testing.expect(log.len > before);
}

// ── Main ───────────────────────────────────────────────────────────

const StderrLogger = struct {
    pub fn info(_: *StderrLogger, msg: []const u8) void { std.debug.print("[INFO] {s}\n", .{msg}); }
    pub fn err(_: *StderrLogger, msg: []const u8) void { std.debug.print("[ERR ] {s}\n", .{msg}); }
};

const WallClock = struct {
    pub fn now_ms(_: *WallClock) i64 { return std.time.milliTimestamp(); }
};

const LiveFlags = struct {
    pub fn enabled(_: *LiveFlags, _: []const u8) bool { return true; }
};

pub fn main() !void {
    var log = StderrLogger{};
    var met = CounterMap{};
    var clk = WallClock{};
    var flg = LiveFlags{};
    fx.init(.{ .{ Logger, &log }, .{ Metrics, &met }, .{ Clock, &clk }, .{ FeatureFlags, &flg } });

    var records = [_]Record{
        .{ .id = "1", .email = "alice@example.com", .payload = "order_100" },
        .{ .id = "2", .email = "", .payload = "order_101" },
        .{ .id = "3", .email = "bad-email", .payload = "order_102" },
        .{ .id = "4", .email = "bob@example.com", .payload = "order_103" },
    };

    const r = processBatch(&records);
    std.debug.print("\nprocessed={d} failed={d} skipped={d}\n", .{ r.processed, r.failed, r.skipped });
    for (met.keys[0..met.len], met.vals[0..met.len]) |k, v|
        std.debug.print("  {s}: {d}\n", .{ k, v });
}
