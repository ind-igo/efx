const efx = @import("efx.zig");

pub const Effect = efx.Effect;
pub const Op = efx.Op;
pub const Scope = efx.Scope;
pub const Slot = efx.Slot;
pub const Contract = efx.Contract;
pub const Exit = efx.Exit;
pub const MAX_EFFECTS = efx.MAX_EFFECTS;

test {
    _ = efx;
}
