//! The securities table: lookups by ISIN, creation from documents and names.

const std = @import("std");
const f = @import("format.zig");
const sqlite = @import("sqlite.zig");

/// The only security with this ISIN, if exactly one exists.
pub fn byIsin(db: sqlite.Db, isin: []const u8) !?i64 {
    var st = try db.prepare("SELECT id FROM security WHERE isin = ? LIMIT 2");
    defer st.finalize();
    try st.bindAll(.{isin});
    if (!try st.step()) return null;
    const id = st.int(0);
    return if (try st.step()) null else id;
}

pub fn add(db: sqlite.Db, isin: []const u8, name: []const u8) !i64 {
    try db.run("INSERT INTO security (isin, name) VALUES (?, ?)", .{ isin, name });
    return db.lastInsertRowId();
}

/// Most securities were seeded with an ISIN only; keeps names already set.
pub fn fillName(db: sqlite.Db, id: i64, name: []const u8) !void {
    try db.run("UPDATE security SET name = ? WHERE id = ? AND TRIM(COALESCE(name, '')) = ''", .{ name, id });
}

pub const SecurityInfo = struct { name: []const u8, isin: []const u8 };

/// Name (blank when never set) and ISIN, allocated from `a`.
pub fn get(db: sqlite.Db, a: std.mem.Allocator, id: i64) !?SecurityInfo {
    var st = try db.prepare("SELECT name, isin FROM security WHERE id = ?");
    defer st.finalize();
    try st.bindAll(.{id});
    if (!try st.step()) return null;
    return .{
        .name = try a.dupe(u8, f.strip(st.textRef(0) orelse "")),
        .isin = try a.dupe(u8, st.textRef(1) orelse ""),
    };
}

fn testDb() !sqlite.Db {
    const db = try sqlite.Db.open(":memory:");
    try @import("migrations.zig").run(db);
    try db.exec("INSERT INTO security (isin, name) VALUES ('US0378331005', ''), ('DE0007164600', 'SAP'), ('DE0007164600', 'SAP dup')");
    return db;
}

test "securities by ISIN, creation and name filling" {
    const db = try testDb();
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(?i64, 1), try byIsin(db, "US0378331005"));
    try std.testing.expectEqual(@as(?i64, null), try byIsin(db, "DE0007164600"));
    try std.testing.expectEqual(@as(?i64, null), try byIsin(db, "IE00B4L5Y983"));
    const id = try add(db, "IE00B4L5Y983", "World ETF");
    try std.testing.expectEqual(@as(?i64, id), try byIsin(db, "IE00B4L5Y983"));

    try fillName(db, 1, "Example Inc.");
    try fillName(db, 2, "Overwritten?");
    try std.testing.expectEqualStrings("Example Inc.", (try get(db, arena.allocator(), 1)).?.name);
    try std.testing.expectEqualStrings("SAP", (try get(db, arena.allocator(), 2)).?.name);
    try std.testing.expect(try get(db, arena.allocator(), 99) == null);
}
