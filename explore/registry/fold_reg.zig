const efx = @import("efx");
const E = efx.Effect(union(enum) { op: efx.Op(u64, u64) });
const G = efx.Effect(union(enum) { a: efx.Op(u64, u64), b: efx.Op(void, void) });
pub const efx_effects = .{ E, G };
const H = struct {
    k: u64 = 7,
    pub fn op(self: *H, v: u64) u64 {
        return v +% self.k;
    }
};
export fn fold_exec(x: u64) u64 {
    var h = H{};
    const sc = efx.Scope.init(.{.{ E, &h }});
    return E.exec(&sc, .op, x);
}
export fn fold_bind(x: u64) u64 {
    var h = H{};
    var h2 = H{ .k = 9 };
    const sc = efx.Scope.init(.{.{ E, &h }});
    const inner = sc.bind(E, &h2);
    return E.exec(&inner, .op, x);
}
pub fn main() void {}
