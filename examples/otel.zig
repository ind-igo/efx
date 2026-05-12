/// OpenTelemetry-style effect example.
/// One effect captures tracing and metrics; handlers decide where records go.
const std = @import("std");
const fx = @import("fx");

// Effect definition

const TraceId = [16]u8;
const SpanId = [8]u8;

const SpanHandle = enum(u32) {
    none = 0,
    _,
};

const SpanKind = enum {
    internal,
    server,
    client,
    producer,
    consumer,
};

const SpanStatus = enum {
    unset,
    ok,
    err,
};

const Value = union(enum) {
    string: []const u8,
    i64: i64,
    u64: u64,
    f64: f64,
    bool: bool,
};

const Attr = struct {
    key: []const u8,
    value: Value,
};

const SpanContext = struct {
    trace_id: TraceId = [_]u8{0} ** 16,
    span_id: SpanId = [_]u8{0} ** 8,
    trace_flags: u8 = 0,
};

const Span = struct {
    handle: SpanHandle,
    context: SpanContext,
};

const StartSpan = struct {
    name: []const u8,
    kind: SpanKind = .internal,
    parent: ?SpanContext = null,
    attrs: []const Attr = &.{},
    start_ns: ?i128 = null,
};

const SpanEvent = struct {
    span: Span,
    name: []const u8,
    attrs: []const Attr = &.{},
    time_ns: ?i128 = null,
};

const SpanStatusUpdate = struct {
    span: Span,
    status: SpanStatus,
    description: []const u8 = "",
};

const EndSpan = struct {
    span: Span,
    end_ns: ?i128 = null,
};

const MetricPoint = struct {
    name: []const u8,
    value: f64,
    unit: []const u8 = "",
    attrs: []const Attr = &.{},
};

const Otel = fx.Effect(union(enum) {
    start_span: fx.Op(StartSpan, Span),
    add_event: fx.Op(SpanEvent, void),
    set_status: fx.Op(SpanStatusUpdate, void),
    end_span: fx.Op(EndSpan, void),
    counter: fx.Op(MetricPoint, void),
    histogram: fx.Op(MetricPoint, void),
});

// Business logic

const Order = struct {
    id: []const u8,
    total_cents: u64,
};

fn checkout(sc: *const fx.Scope, order: Order) bool {
    const span = Otel.exec(sc, .start_span, .{
        .name = "checkout",
        .kind = .server,
        .attrs = &.{
            .{ .key = "order.id", .value = .{ .string = order.id } },
            .{ .key = "order.total_cents", .value = .{ .u64 = order.total_cents } },
        },
    });
    defer Otel.exec(sc, .end_span, .{ .span = span });

    if (order.total_cents == 0) {
        Otel.exec(sc, .add_event, .{ .span = span, .name = "empty order" });
        Otel.exec(sc, .set_status, .{ .span = span, .status = .err, .description = "empty order" });
        Otel.exec(sc, .counter, .{ .name = "checkout.failed", .value = 1 });
        return false;
    }

    Otel.exec(sc, .add_event, .{ .span = span, .name = "payment authorized" });
    Otel.exec(sc, .histogram, .{
        .name = "checkout.total",
        .value = @floatFromInt(order.total_cents),
        .unit = "cents",
    });
    Otel.exec(sc, .counter, .{ .name = "checkout.completed", .value = 1 });
    Otel.exec(sc, .set_status, .{ .span = span, .status = .ok });
    return true;
}

// Handlers

const NoopOtel = struct {
    pub fn start_span(_: *NoopOtel, _: StartSpan) Span {
        return .{ .handle = .none, .context = .{} };
    }
    pub fn add_event(_: *NoopOtel, _: SpanEvent) void {}
    pub fn set_status(_: *NoopOtel, _: SpanStatusUpdate) void {}
    pub fn end_span(_: *NoopOtel, _: EndSpan) void {}
    pub fn counter(_: *NoopOtel, _: MetricPoint) void {}
    pub fn histogram(_: *NoopOtel, _: MetricPoint) void {}
};

const TestOtel = struct {
    spans: [16]StartSpan = undefined,
    events: [32]SpanEvent = undefined,
    statuses: [16]SpanStatusUpdate = undefined,
    counters: [16]MetricPoint = undefined,
    histograms: [16]MetricPoint = undefined,
    ended: [16]EndSpan = undefined,
    span_len: usize = 0,
    event_len: usize = 0,
    status_len: usize = 0,
    counter_len: usize = 0,
    histogram_len: usize = 0,
    ended_len: usize = 0,
    next_id: u32 = 1,

    pub fn start_span(self: *TestOtel, args: StartSpan) Span {
        const id = self.next_id;
        self.next_id += 1;
        if (self.span_len < self.spans.len) {
            self.spans[self.span_len] = args;
            self.span_len += 1;
        }
        return .{
            .handle = @enumFromInt(id),
            .context = .{
                .trace_id = traceId(id),
                .span_id = spanId(id),
                .trace_flags = 1,
            },
        };
    }

    pub fn add_event(self: *TestOtel, event: SpanEvent) void {
        if (self.event_len < self.events.len) {
            self.events[self.event_len] = event;
            self.event_len += 1;
        }
    }

    pub fn set_status(self: *TestOtel, update: SpanStatusUpdate) void {
        if (self.status_len < self.statuses.len) {
            self.statuses[self.status_len] = update;
            self.status_len += 1;
        }
    }

    pub fn end_span(self: *TestOtel, end: EndSpan) void {
        if (self.ended_len < self.ended.len) {
            self.ended[self.ended_len] = end;
            self.ended_len += 1;
        }
    }

    pub fn counter(self: *TestOtel, point: MetricPoint) void {
        if (self.counter_len < self.counters.len) {
            self.counters[self.counter_len] = point;
            self.counter_len += 1;
        }
    }

    pub fn histogram(self: *TestOtel, point: MetricPoint) void {
        if (self.histogram_len < self.histograms.len) {
            self.histograms[self.histogram_len] = point;
            self.histogram_len += 1;
        }
    }

    fn countCounter(self: *const TestOtel, name: []const u8) f64 {
        var total: f64 = 0;
        for (self.counters[0..self.counter_len]) |point| {
            if (std.mem.eql(u8, point.name, name)) total += point.value;
        }
        return total;
    }
};

const StderrOtel = struct {
    next_id: u32 = 1,

    pub fn start_span(self: *StderrOtel, args: StartSpan) Span {
        const id = self.next_id;
        self.next_id += 1;
        const context = SpanContext{ .trace_id = traceId(id), .span_id = spanId(id), .trace_flags = 1 };
        std.debug.print("span start name={s} kind={s} span={d}\n", .{
            args.name,
            @tagName(args.kind),
            id,
        });
        return .{ .handle = @enumFromInt(id), .context = context };
    }

    pub fn add_event(_: *StderrOtel, event: SpanEvent) void {
        std.debug.print("span event name={s} span={d}\n", .{
            event.name,
            @intFromEnum(event.span.handle),
        });
    }

    pub fn set_status(_: *StderrOtel, update: SpanStatusUpdate) void {
        std.debug.print("span status status={s} desc={s}\n", .{ @tagName(update.status), update.description });
    }

    pub fn end_span(_: *StderrOtel, end: EndSpan) void {
        std.debug.print("span end span={d}\n", .{@intFromEnum(end.span.handle)});
    }

    pub fn counter(_: *StderrOtel, point: MetricPoint) void {
        std.debug.print("metric counter name={s} value={d}\n", .{ point.name, point.value });
    }

    pub fn histogram(_: *StderrOtel, point: MetricPoint) void {
        std.debug.print("metric histogram name={s} value={d} unit={s}\n", .{ point.name, point.value, point.unit });
    }
};

fn traceId(id: u32) TraceId {
    var out = [_]u8{0} ** 16;
    const sid = spanId(id);
    @memcpy(out[8..16], sid[0..8]);
    return out;
}

fn spanId(id: u32) SpanId {
    var out = [_]u8{0} ** 8;
    var n: u32 = id;
    var i: usize = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = @intCast(n & 0xff);
        n >>= 8;
    }
    return out;
}

// Tests

test "checkout records a successful span and metrics" {
    var otel = TestOtel{};
    const sc = fx.Scope.init(.{.{ Otel, &otel }});

    try std.testing.expect(checkout(&sc, .{ .id = "ord_1", .total_cents = 2599 }));

    try std.testing.expectEqual(@as(usize, 1), otel.span_len);
    try std.testing.expectEqualStrings("checkout", otel.spans[0].name);
    try std.testing.expectEqual(@as(usize, 1), otel.event_len);
    try std.testing.expectEqualStrings("payment authorized", otel.events[0].name);
    try std.testing.expectEqual(@as(usize, 1), otel.ended_len);
    try std.testing.expectEqual(@as(f64, 1), otel.countCounter("checkout.completed"));
    try std.testing.expectEqual(@as(usize, 1), otel.histogram_len);
    try std.testing.expectEqualStrings("checkout.total", otel.histograms[0].name);
    try std.testing.expectEqual(SpanStatus.ok, otel.statuses[0].status);
}

test "checkout records a failed span" {
    var otel = TestOtel{};
    const sc = fx.Scope.init(.{.{ Otel, &otel }});

    try std.testing.expect(!checkout(&sc, .{ .id = "ord_empty", .total_cents = 0 }));

    try std.testing.expectEqual(@as(usize, 1), otel.span_len);
    try std.testing.expectEqual(@as(usize, 1), otel.event_len);
    try std.testing.expectEqualStrings("empty order", otel.events[0].name);
    try std.testing.expectEqual(SpanStatus.err, otel.statuses[0].status);
    try std.testing.expectEqual(@as(f64, 1), otel.countCounter("checkout.failed"));
    try std.testing.expectEqual(@as(usize, 1), otel.ended_len);
}

test "observability can be disabled with a no-op handler" {
    var otel = NoopOtel{};
    const sc = fx.Scope.init(.{.{ Otel, &otel }});

    try std.testing.expect(checkout(&sc, .{ .id = "ord_2", .total_cents = 100 }));
}

// Main

pub fn main(_: std.process.Init) !void {
    var otel = StderrOtel{};
    const sc = fx.Scope.init(.{.{ Otel, &otel }});

    _ = checkout(&sc, .{ .id = "ord_42", .total_cents = 4200 });
    _ = checkout(&sc, .{ .id = "ord_empty", .total_cents = 0 });
}
