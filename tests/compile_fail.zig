//! Each test here must fail to compile, so none of them can run in the normal
//! suite. build.zig compiles them one at a time with a test filter and checks
//! the error message. `control` compiles, which proves a failure comes from the
//! case itself and not from this file.
const efx = @import("efx");

const Clock = efx.Effect(union(enum) { now: efx.Op(void, i64) });
const Log = efx.Effect(union(enum) { info: efx.Op(void, void) });

const Handler = struct {
    pub fn now(_: *Handler) i64 {
        return 1;
    }
    pub fn info(_: *Handler) void {}
};

const Small = efx.Contract(.{Clock});
const Big = efx.Contract(.{ Clock, Log });

fn useLog(sc: *const Small) void {
    Log.exec(sc, .info, {});
}

fn deepUseLog(sc: *const Small) void {
    useLog(sc);
}

fn wantsBig(_: *const Big) void {}

/// Handles Clock and uses Log, so it needs a contract that lists Log.
const LoggingClock = struct {
    pub fn now(_: *LoggingClock, sc: *const efx.Contract(.{Log})) i64 {
        Log.exec(sc, .info, {});
        return 1;
    }
};

const WrongScopeParam = struct {
    pub fn now(_: *WrongScopeParam, _: *efx.Scope) i64 {
        return 1;
    }
};

test "control" {
    var h = Handler{};
    const big = Big.init(.{ .{ Clock, &h }, .{ Log, &h } });
    _ = Clock.exec(Small.from(&big), .now, {});
    var clock = LoggingClock{};
    _ = Big.init(.{ .{ Clock, &clock }, .{ Log, &h } });
}

test "exec_unlisted" {
    var h = Handler{};
    const sc = Small.init(.{.{ Clock, &h }});
    deepUseLog(&sc);
}

test "from_missing" {
    var h = Handler{};
    const sc = Small.init(.{.{ Clock, &h }});
    wantsBig(Big.from(&sc));
}

test "init_missing" {
    var h = Handler{};
    _ = Big.init(.{.{ Clock, &h }});
}

test "bind_unlisted" {
    var h = Handler{};
    const sc = Small.init(.{.{ Clock, &h }});
    _ = sc.bind(Log, &h);
}

test "from_plain_scope" {
    var h = Handler{};
    const sc = efx.Scope.init(.{.{ Clock, &h }});
    _ = Small.from(&sc);
}

test "handler_uses_unlisted_init" {
    var clock = LoggingClock{};
    _ = Small.init(.{.{ Clock, &clock }});
}

test "handler_uses_unlisted_bind" {
    var h = Handler{};
    var clock = LoggingClock{};
    const sc = Small.init(.{.{ Clock, &h }});
    _ = sc.bind(Clock, &clock);
}

test "handler_wrong_scope_param" {
    var h = WrongScopeParam{};
    _ = efx.Scope.init(.{.{ Clock, &h }});
}

test "exec_by_value" {
    var h = Handler{};
    const sc = Small.init(.{.{ Clock, &h }});
    _ = Clock.exec(sc, .now, {});
}
