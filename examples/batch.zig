//! Batch operations: putting an effect on a hot path.
//!
//! An effect per element costs an indirect call per element and stops the
//! optimizer inlining the handler. Passing a whole column moves the loop into
//! the handler, where it compiles as a plain tight loop, and a remote handler
//! can make one request instead of thousands. Nothing here is special to efx:
//! the operation just takes a slice.
const std = @import("std");
const efx = @import("efx");

// ── Effect ──────────────────────────────────────────────────────────

const Lookup = struct {
    skus: []const u32,
    prices: []u32,
};

const Prices = efx.Effect(union(enum) {
    lookup: efx.Op(Lookup, error{Unavailable}!void),
});

// ── Business logic ──────────────────────────────────────────────────

/// An order is two columns. `prices` is caller-provided scratch space.
fn orderTotal(
    sc: *const efx.Scope,
    skus: []const u32,
    quantities: []const u32,
    prices: []u32,
) error{Unavailable}!u64 {
    const row_prices = prices[0..skus.len];
    try Prices.exec(sc, .lookup, .{ .skus = skus, .prices = row_prices });

    var total: u64 = 0;
    for (quantities, row_prices) |quantity, price| total += @as(u64, quantity) * price;
    return total;
}

// ── Handlers ────────────────────────────────────────────────────────

/// In memory: the loop lives here, so it inlines and vectorizes.
const TablePrices = struct {
    table: []const u32,

    pub fn lookup(self: *TablePrices, req: Lookup) error{Unavailable}!void {
        for (req.skus, req.prices) |sku, *price| price.* = self.table[sku];
    }
};

/// Stands in for a price service. It decides how to split the work, and the
/// caller doesn't need to know.
const RemotePrices = struct {
    table: []const u32,
    page_size: usize,
    round_trips: u32 = 0,

    pub fn lookup(self: *RemotePrices, req: Lookup) error{Unavailable}!void {
        var start: usize = 0;
        while (start < req.skus.len) : (start += self.page_size) {
            const end = @min(start + self.page_size, req.skus.len);
            self.round_trips += 1;
            for (req.skus[start..end], req.prices[start..end]) |sku, *price| {
                price.* = self.table[sku];
            }
        }
    }
};

const Outage = struct {
    pub fn lookup(_: *Outage, _: Lookup) error{Unavailable}!void {
        return error.Unavailable;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const table = [_]u32{ 100, 250, 999, 5 };

test "totals an order from a table" {
    var handler = TablePrices{ .table = &table };
    const sc = efx.Scope.init(.{.{ Prices, &handler }});
    var prices: [3]u32 = undefined;

    const total = try orderTotal(&sc, &.{ 2, 0, 3 }, &.{ 1, 3, 10 }, &prices);

    try std.testing.expectEqual(@as(u64, 999 + 300 + 50), total);
}

test "an empty order costs nothing" {
    var handler = RemotePrices{ .table = &table, .page_size = 100 };
    const sc = efx.Scope.init(.{.{ Prices, &handler }});
    var prices: [1]u32 = undefined;

    try std.testing.expectEqual(@as(u64, 0), try orderTotal(&sc, &.{}, &.{}, &prices));
    try std.testing.expectEqual(@as(u32, 0), handler.round_trips);
}

test "a remote handler pages the whole column, and the total doesn't change" {
    var skus: [1000]u32 = undefined;
    var quantities: [1000]u32 = undefined;
    for (&skus, &quantities, 0..) |*sku, *quantity, i| {
        sku.* = @intCast(i / 3 % table.len); // differs from page to page
        quantity.* = @intCast(i % 7 + 1);
    }
    var prices: [1000]u32 = undefined;

    var local = TablePrices{ .table = &table };
    const local_scope = efx.Scope.init(.{.{ Prices, &local }});
    const expected = try orderTotal(&local_scope, &skus, &quantities, &prices);

    var remote = RemotePrices{ .table = &table, .page_size = 100 };
    const remote_scope = local_scope.bind(Prices, &remote);
    const total = try orderTotal(&remote_scope, &skus, &quantities, &prices);

    try std.testing.expectEqual(expected, total);
    try std.testing.expectEqual(@as(u32, 10), remote.round_trips);
}

test "a failed lookup reaches the caller" {
    var outage = Outage{};
    const sc = efx.Scope.init(.{.{ Prices, &outage }});
    var prices: [1]u32 = undefined;

    try std.testing.expectError(error.Unavailable, orderTotal(&sc, &.{0}, &.{1}, &prices));
}

pub fn main(_: std.process.Init) !void {
    const skus = [_]u32{ 2, 0, 3 };
    const quantities = [_]u32{ 1, 3, 10 };
    var prices: [skus.len]u32 = undefined;

    var handler = RemotePrices{ .table = &table, .page_size = 2 };
    const sc = efx.Scope.init(.{.{ Prices, &handler }});

    const total = try orderTotal(&sc, &skus, &quantities, &prices);
    std.debug.print("total={d} round_trips={d}\n", .{ total, handler.round_trips });
}
