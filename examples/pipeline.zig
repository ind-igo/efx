/// Data-processing pipeline — validate → enrich → store.
/// Four effects compose naturally; tests swap all handlers to deterministic versions.
const std = @import("std");
const efx = @import("efx");

// ── Effects ────────────────────────────────────────────────────────

const Logger = efx.Effect(union(enum) { info: efx.Op([]const u8, void), err: efx.Op([]const u8, void) });
const Metrics = efx.Effect(union(enum) { inc: efx.Op([]const u8, void), get: efx.Op([]const u8, u64) });
const Clock = efx.Effect(union(enum) { now_ms: efx.Op(void, i64) });
const FeatureFlags = efx.Effect(union(enum) { enabled: efx.Op([]const u8, bool) });

const Pipeline = efx.Contract(.{ Logger, Metrics, Clock, FeatureFlags });

// ── Domain ─────────────────────────────────────────────────────────

const Record = struct { id: []const u8, email: []const u8, payload: []const u8, enriched_at: i64 = 0, stored_at: i64 = 0 };
const Result = struct { processed: u32 = 0, failed: u32 = 0, skipped: u32 = 0 };

// ── Pipeline stages ────────────────────────────────────────────────

fn validate(sc: *const efx.Scope, rec: *const Record) bool {
    if (rec.email.len == 0) {
        Logger.exec(sc, .err, "missing email");
        Metrics.exec(sc, .inc, "validate.fail");
        return false;
    }
    for (rec.email) |c| {
        if (c == '@') {
            Metrics.exec(sc, .inc, "validate.pass");
            return true;
        }
    }
    Logger.exec(sc, .err, "invalid email");
    Metrics.exec(sc, .inc, "validate.fail");
    return false;
}

fn enrich(sc: *const efx.Scope, rec: *Record) void {
    if (!FeatureFlags.exec(sc, .enabled, "enrichment")) {
        Logger.exec(sc, .info, "enrichment skipped");
        return;
    }
    rec.enriched_at = Clock.exec(sc, .now_ms, {});
    Metrics.exec(sc, .inc, "enrich.ok");
}

fn store(sc: *const efx.Scope, rec: *Record) void {
    rec.stored_at = Clock.exec(sc, .now_ms, {});
    Logger.exec(sc, .info, "stored");
    Metrics.exec(sc, .inc, "store.ok");
}

fn processBatch(sc: *const efx.Scope, records: []Record) Result {
    var r = Result{};
    Logger.exec(sc, .info, "batch start");
    for (records) |*rec| {
        if (!validate(sc, rec)) { r.failed += 1; continue; }
        enrich(sc, rec);
        if (rec.enriched_at == 0 and FeatureFlags.exec(sc, .enabled, "enrichment")) { r.skipped += 1; continue; }
        store(sc, rec);
        r.processed += 1;
    }
    Logger.exec(sc, .info, "batch end");
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

fn testScope(log: *TestLogger, met: *CounterMap, clk: *TestClock, flg: *TestFlags) efx.Scope {
    return Pipeline.init(.{ .{ Logger, log }, .{ Metrics, met }, .{ Clock, clk }, .{ FeatureFlags, flg } });
}

// ── Tests ──────────────────────────────────────────────────────────

test "happy path: valid records are enriched and stored" {
    var log = TestLogger{};
    var met = CounterMap{};
    var clk = TestClock{};
    var flg = TestFlags{};
    const sc = testScope(&log, &met, &clk, &flg);

    var recs = [_]Record{
        .{ .id = "1", .email = "a@b.com", .payload = "d1" },
        .{ .id = "2", .email = "c@d.org", .payload = "d2" },
    };
    const r = processBatch(&sc, &recs);

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
    const sc = testScope(&log, &met, &clk, &flg);

    var recs = [_]Record{
        .{ .id = "x", .email = "", .payload = "a" },
        .{ .id = "y", .email = "no-at", .payload = "b" },
        .{ .id = "z", .email = "ok@ok", .payload = "c" },
    };
    const r = processBatch(&sc, &recs);

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
    const sc = testScope(&log, &met, &clk, &flg);

    var recs = [_]Record{.{ .id = "1", .email = "a@b.com", .payload = "d" }};
    const r = processBatch(&sc, &recs);

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
    const sc = testScope(&log, &met, &clk, &flg);

    var r1 = [_]Record{.{ .id = "1", .email = "a@b.com", .payload = "d" }};
    _ = processBatch(&sc, &r1);
    const before = log.len;
    try std.testing.expect(before > 0);

    var silent = struct {
        pub fn info(_: *@This(), _: []const u8) void {}
        pub fn err(_: *@This(), _: []const u8) void {}
    }{};
    const quiet = sc.bind(Logger, &silent);

    var r2 = [_]Record{.{ .id = "2", .email = "x@y.com", .payload = "d" }};
    _ = processBatch(&quiet, &r2);
    try std.testing.expectEqual(before, log.len);

    var r3 = [_]Record{.{ .id = "3", .email = "z@w.com", .payload = "d" }};
    _ = processBatch(&sc, &r3);
    try std.testing.expect(log.len > before);
}

// ── Main ───────────────────────────────────────────────────────────

const StderrLogger = struct {
    pub fn info(_: *StderrLogger, msg: []const u8) void { std.debug.print("[INFO] {s}\n", .{msg}); }
    pub fn err(_: *StderrLogger, msg: []const u8) void { std.debug.print("[ERR ] {s}\n", .{msg}); }
};

const WallClock = struct {
    io: std.Io,
    pub fn now_ms(self: *WallClock) i64 {
        return std.Io.Clock.Timestamp.now(self.io, .real).raw.toMilliseconds();
    }
};

const LiveFlags = struct {
    pub fn enabled(_: *LiveFlags, _: []const u8) bool { return true; }
};

pub fn main(init: std.process.Init) !void {
    var log = StderrLogger{};
    var met = CounterMap{};
    var clk = WallClock{ .io = init.io };
    var flg = LiveFlags{};
    const sc = Pipeline.init(.{ .{ Logger, &log }, .{ Metrics, &met }, .{ Clock, &clk }, .{ FeatureFlags, &flg } });

    var records = [_]Record{
        .{ .id = "1", .email = "alice@example.com", .payload = "order_100" },
        .{ .id = "2", .email = "", .payload = "order_101" },
        .{ .id = "3", .email = "bad-email", .payload = "order_102" },
        .{ .id = "4", .email = "bob@example.com", .payload = "order_103" },
    };

    const r = processBatch(&sc, &records);
    std.debug.print("\nprocessed={d} failed={d} skipped={d}\n", .{ r.processed, r.failed, r.skipped });
    for (met.keys[0..met.len], met.vals[0..met.len]) |k, v|
        std.debug.print("  {s}: {d}\n", .{ k, v });
}
