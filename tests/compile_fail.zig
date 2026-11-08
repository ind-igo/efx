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

test "control" {
    var h = Handler{};
    const big = Big.init(.{ .{ Clock, &h }, .{ Log, &h } });
    _ = Clock.exec(Small.from(&big), .now, {});
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

test "exec_by_value" {
    var h = Handler{};
    const sc = Small.init(.{.{ Clock, &h }});
    _ = Clock.exec(sc, .now, {});
}
