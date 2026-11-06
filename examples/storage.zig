//! Crash-recovery testing for a write-ahead log.
//!
//! The disk is a real boundary: production hits a file, tests use memory, and
//! a wrapping handler crashes the "machine" at an exact operation. The test
//! sweeps every crash point and checks the one promise a WAL makes: a write
//! that was acknowledged survives.
//!
//! Only the disk and the logger are effects. Encoding and checksums are pure
//! functions; routing them through a handler would add indirection, not value.
const std = @import("std");
const efx = @import("efx");

// ── Effects ─────────────────────────────────────────────────────────

const DiskError = error{ IoFailure, Crashed };

const Disk = efx.Effect(union(enum) {
    append: efx.Op([]const u8, DiskError!void),
    sync: efx.Op(void, DiskError!void),
    read_all: efx.Op([]u8, DiskError![]const u8),
});

const Logger = efx.Effect(union(enum) {
    warn: efx.Op([]const u8, void),
});

/// Everything the WAL needs. Forgetting one is a compile error at the wiring
/// site rather than a panic on first dispatch.
const WalEffects = efx.Contract(.{ Disk, Logger });

// ── Write-ahead log ─────────────────────────────────────────────────

const header_len = 8; // u32 payload length + u32 CRC-32, little endian

/// Returns only once `entry` is durable.
fn put(sc: *const efx.Scope, entry: []const u8) DiskError!void {
    var header: [header_len]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(entry.len), .little);
    std.mem.writeInt(u32, header[4..8], std.hash.Crc32.hash(entry), .little);

    try Disk.exec(sc, .append, &header);
    try Disk.exec(sc, .append, entry);
    try Disk.exec(sc, .sync, {});
}

/// Replays the log into `out`, stopping at the first torn or corrupt record.
fn recover(sc: *const efx.Scope, buf: []u8, out: [][]const u8) DiskError![]const []const u8 {
    const bytes = try Disk.exec(sc, .read_all, buf);
    var pos: usize = 0;
    var count: usize = 0;

    while (count < out.len and bytes.len - pos >= header_len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        const crc = std.mem.readInt(u32, bytes[pos..][4..8], .little);
        const body = pos + header_len;
        if (bytes.len - body < len) break;

        const entry = bytes[body..][0..len];
        if (std.hash.Crc32.hash(entry) != crc) break;

        out[count] = entry;
        count += 1;
        pos = body + len;
    }

    if (pos != bytes.len and count < out.len) Logger.exec(sc, .warn, "discarding torn tail");
    return out[0..count];
}

// ── Handlers ────────────────────────────────────────────────────────

const FileDisk = struct {
    io: std.Io,
    file: std.Io.File,
    len: u64 = 0,

    pub fn append(self: *FileDisk, bytes: []const u8) DiskError!void {
        self.file.writePositionalAll(self.io, bytes, self.len) catch return error.IoFailure;
        self.len += bytes.len;
    }

    pub fn sync(self: *FileDisk) DiskError!void {
        self.file.sync(self.io) catch return error.IoFailure;
    }

    pub fn read_all(self: *FileDisk, out: []u8) DiskError![]const u8 {
        const n = self.file.readPositionalAll(self.io, out, 0) catch return error.IoFailure;
        return out[0..n];
    }
};

const StderrLogger = struct {
    pub fn warn(_: *StderrLogger, msg: []const u8) void {
        std.debug.print("[WARN] {s}\n", .{msg});
    }
};

/// Tracks which bytes reached stable storage, so a test can lose the rest.
const MemDisk = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    synced: usize = 0,

    pub fn append(self: *MemDisk, bytes: []const u8) DiskError!void {
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn sync(self: *MemDisk) DiskError!void {
        self.synced = self.len;
    }

    pub fn read_all(self: *MemDisk, out: []u8) DiskError![]const u8 {
        @memcpy(out[0..self.len], self.buf[0..self.len]);
        return out[0..self.len];
    }

    fn losePowerDroppingUnsynced(self: *MemDisk) void {
        self.len = self.synced;
    }
};

/// Wraps whichever disk `inner` has bound and crashes at a chosen operation,
/// leaving half of the in-flight append behind. The wrapper knows nothing
/// about the disk under it, so it works on `MemDisk` and `FileDisk` alike.
const CrashAfter = struct {
    inner: *const efx.Scope,
    ops_left: usize,

    pub fn append(self: *CrashAfter, bytes: []const u8) DiskError!void {
        if (self.ops_left == 0) {
            try Disk.exec(self.inner, .append, bytes[0 .. bytes.len / 2]);
            return error.Crashed;
        }
        self.ops_left -= 1;
        return Disk.exec(self.inner, .append, bytes);
    }

    pub fn sync(self: *CrashAfter) DiskError!void {
        if (self.ops_left == 0) return error.Crashed;
        self.ops_left -= 1;
        return Disk.exec(self.inner, .sync, {});
    }

    pub fn read_all(self: *CrashAfter, out: []u8) DiskError![]const u8 {
        return Disk.exec(self.inner, .read_all, out);
    }
};

const TestLogger = struct {
    warnings: usize = 0,

    pub fn warn(self: *TestLogger, _: []const u8) void {
        self.warnings += 1;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

const entries = [_][]const u8{ "alpha", "bravo", "charlie" };
const ops_per_put = 3; // header append, payload append, sync

test "every acknowledged write survives a crash at any point" {
    for ([_]bool{ true, false }) |lose_unsynced| {
        for (0..entries.len * ops_per_put + 1) |crash_at| {
            var disk = MemDisk{};
            var log = TestLogger{};
            const base = WalEffects.init(.{ .{ Disk, &disk }, .{ Logger, &log } });

            var crash = CrashAfter{ .inner = &base, .ops_left = crash_at };
            const sc = base.bind(Disk, &crash);

            var acked: usize = 0;
            for (entries) |entry| {
                put(&sc, entry) catch break;
                acked += 1;
            }
            try std.testing.expectEqual(crash_at / ops_per_put, acked);
            if (lose_unsynced) disk.losePowerDroppingUnsynced();

            var buf: [1024]u8 = undefined;
            var out: [entries.len][]const u8 = undefined;
            const recovered = try recover(&base, &buf, &out);

            try std.testing.expect(recovered.len >= acked);
            for (recovered, entries[0..recovered.len]) |got, want| {
                try std.testing.expectEqualStrings(want, got);
            }
        }
    }
}

test "recovery stops at a corrupt record and warns" {
    var disk = MemDisk{};
    var log = TestLogger{};
    const sc = WalEffects.init(.{ .{ Disk, &disk }, .{ Logger, &log } });

    try put(&sc, "good");
    try put(&sc, "bad");
    disk.buf[disk.len - 1] ^= 0xff;

    var buf: [1024]u8 = undefined;
    var out: [2][]const u8 = undefined;
    const recovered = try recover(&sc, &buf, &out);

    try std.testing.expectEqual(@as(usize, 1), recovered.len);
    try std.testing.expectEqualStrings("good", recovered[0]);
    try std.testing.expectEqual(@as(usize, 1), log.warnings);
}

// ── Main: the same WAL against a real file ──────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const dir = std.Io.Dir.cwd();
    const path = "efx-example.wal";

    const file = try dir.createFile(io, path, .{ .read = true, .truncate = true });
    defer dir.deleteFile(io, path) catch {};
    defer file.close(io);

    var disk = FileDisk{ .io = io, .file = file };
    var log = StderrLogger{};
    const sc = WalEffects.init(.{ .{ Disk, &disk }, .{ Logger, &log } });

    for (entries) |entry| try put(&sc, entry);

    var buf: [1024]u8 = undefined;
    var out: [entries.len][]const u8 = undefined;
    for (try recover(&sc, &buf, &out)) |entry| std.debug.print("recovered: {s}\n", .{entry});
}
