//! A missing handler must panic and name the effect in every build mode. This
//! can't be a `test` block because the panic ends the process: build.zig runs
//! this program and checks how it dies.
const std = @import("std");
const efx = @import("efx");

const NeverBound = efx.Effect(union(enum) { op: efx.Op(u64, u64) });
const BoundElsewhere = efx.Effect(union(enum) { op: efx.Op(u64, u64) });
const Other = efx.Effect(union(enum) { op: efx.Op(u64, u64) });

const Handler = struct {
    pub fn op(_: *Handler, v: u64) u64 {
        return v;
    }
};

pub fn main(init: std.process.Init) void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const case = args.next().?;

    var handler = Handler{};
    const with_it = efx.Scope.init(.{.{ BoundElsewhere, &handler }});
    const without_it = efx.Scope.init(.{.{ Other, &handler }});
    std.debug.assert(BoundElsewhere.exec(&with_it, .op, 7) == 7);

    if (std.mem.eql(u8, case, "never")) {
        _ = NeverBound.exec(&without_it, .op, 1);
    } else {
        _ = BoundElsewhere.exec(&without_it, .op, 1);
    }
    std.process.exit(0); // Reaching this is the failure: the check expects SIGABRT.
}
