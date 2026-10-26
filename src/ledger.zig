//! Writes and queries on the stored ledger, and the invariants checked
//! before a write is committed.

const std = @import("std");
const assert = std.debug.assert;
const f = @import("format.zig");
const sqlite = @import("sqlite.zig");

/// The two legs of a transfer reference each other and cancel out.
pub fn assertTransferPair(db: sqlite.Db, a: i64, b: i64) !void {
    assert(a != b);
    var st = try db.prepare(
        \\SELECT COUNT(*),
        \\       COALESCE(SUM(total_value), 0),
        \\       SUM((id = ?1 AND linked_transaction = ?2) OR (id = ?2 AND linked_transaction = ?1))
        \\FROM "transaction" WHERE id IN (?1, ?2) AND type = 'transfer'
    );
    defer st.finalize();
    try st.bindAll(.{ a, b });
    assert(try st.step());
    assert(st.int(0) == 2);
    assert(st.int(1) == 0);
    assert(st.int(2) == 2);
}

/// A transaction about to be written; quantity in millionths of a share.
pub const Entry = struct {
    account: i64,
    /// "buy", "sell", "dividend", "interest", "deposit" or "withdrawal".
    kind: []const u8,
    security: ?i64,
    quantity: i64,
    unit: i64,
    total: i64,
    cost: i64,
    /// ISO date.
    date: []const u8,
    currency: []const u8,
    exchange_rate: f64,

    fn hasQuantity(e: Entry) bool {
        return std.mem.eql(u8, e.kind, "buy") or std.mem.eql(u8, e.kind, "sell");
    }
};

/// Same column choice as `dv add`: quantity and unit only for trades,
/// security only where one applies.
pub fn insert(db: sqlite.Db, e: Entry) !i64 {
    if (e.hasQuantity()) {
        try db.run(
            \\INSERT INTO "transaction"
            \\   (account, security, type, quantity, unit_value, total_value, cost, date, currency, exchange_rate)
            \\   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        , .{ e.account, e.security.?, e.kind, e.quantity, e.unit, e.total, e.cost, e.date, e.currency, e.exchange_rate });
    } else if (e.security) |sid| {
        try db.run(
            \\INSERT INTO "transaction"
            \\   (account, security, type, total_value, cost, date, currency, exchange_rate)
            \\   VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        , .{ e.account, sid, e.kind, e.total, e.cost, e.date, e.currency, e.exchange_rate });
    } else {
        try db.run(
            \\INSERT INTO "transaction"
            \\   (account, type, total_value, cost, date, currency, exchange_rate)
            \\   VALUES (?, ?, ?, ?, ?, ?, ?)
        , .{ e.account, e.kind, e.total, e.cost, e.date, e.currency, e.exchange_rate });
    }
    return db.lastInsertRowId();
}

/// Same type, quantity and amount within ten days: earlier records sometimes
/// carry the value date instead of the trade date.
pub fn findDuplicate(db: sqlite.Db, e: Entry) !?i64 {
    var st = try db.prepare(
        \\SELECT id FROM "transaction"
        \\WHERE account = ? AND type = ? AND total_value = ? AND COALESCE(quantity, ?) = ?
        \\  AND ABS(julianday(date) - julianday(?)) <= 10
        \\ORDER BY ABS(julianday(date) - julianday(?)) LIMIT 1
    );
    defer st.finalize();
    const qty = if (e.hasQuantity()) e.quantity else f.quantity_scale;
    try st.bindAll(.{ e.account, e.kind, e.total, f.quantity_scale, qty, e.date, e.date });
    return if (try st.step()) st.int(0) else null;
}

/// Shares held, not counting `except` (the recorded copy of a re-imported sell).
pub fn holdings(db: sqlite.Db, account: i64, security_id: i64, except: ?i64) !i64 {
    var st = try db.prepare(
        \\SELECT COALESCE(SUM(CASE WHEN type = 'buy' THEN quantity WHEN type = 'sell' THEN -quantity ELSE 0 END), 0)
        \\FROM "transaction" WHERE account = ? AND security = ? AND id IS NOT ?
    );
    defer st.finalize();
    try st.bindAll(.{ account, security_id, except });
    _ = try st.step();
    return st.int(0);
}

/// The only security with this ISIN, if exactly one exists.
pub fn securityByIsin(db: sqlite.Db, isin: []const u8) !?i64 {
    var st = try db.prepare("SELECT id FROM security WHERE isin = ? LIMIT 2");
    defer st.finalize();
    try st.bindAll(.{isin});
    if (!try st.step()) return null;
    const id = st.int(0);
    return if (try st.step()) null else id;
}

pub fn addSecurity(db: sqlite.Db, isin: []const u8, name: []const u8) !i64 {
    try db.run("INSERT INTO security (isin, name) VALUES (?, ?)", .{ isin, name });
    return db.lastInsertRowId();
}

/// Most securities were seeded with an ISIN only; keeps names already set.
pub fn fillSecurityName(db: sqlite.Db, id: i64, name: []const u8) !void {
    try db.run("UPDATE security SET name = ? WHERE id = ? AND TRIM(COALESCE(name, '')) = ''", .{ name, id });
}

pub const SecurityInfo = struct { name: []const u8, isin: []const u8 };

/// Name (blank when never set) and ISIN, allocated from `a`.
pub fn security(db: sqlite.Db, a: std.mem.Allocator, id: i64) !?SecurityInfo {
    var st = try db.prepare("SELECT name, isin FROM security WHERE id = ?");
    defer st.finalize();
    try st.bindAll(.{id});
    if (!try st.step()) return null;
    return .{
        .name = try a.dupe(u8, f.strip(st.textRef(0) orelse "")),
        .isin = try a.dupe(u8, st.textRef(1) orelse ""),
    };
}

test "transfer pair" {
    const db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.exec(
        \\CREATE TABLE "transaction" (id INTEGER PRIMARY KEY, type TEXT, total_value INTEGER, linked_transaction INTEGER);
        \\INSERT INTO "transaction" VALUES (1, 'transfer', -500, 2), (2, 'transfer', 500, 1);
    );
    try assertTransferPair(db, 1, 2);
    try assertTransferPair(db, 2, 1);
}

fn testDb() !sqlite.Db {
    const db = try sqlite.Db.open(":memory:");
    try @import("migrations.zig").run(db);
    try db.exec("INSERT INTO account (name) VALUES ('Broker')");
    try db.exec("INSERT INTO security (isin, name) VALUES ('US0378331005', ''), ('DE0007164600', 'SAP'), ('DE0007164600', 'SAP dup')");
    return db;
}

fn entry(kind: []const u8, security_id: ?i64, quantity: i64, total: i64, date: []const u8) Entry {
    return .{ .account = 1, .kind = kind, .security = security_id, .quantity = quantity, .unit = 0, .total = total, .cost = 0, .date = date, .currency = "EUR", .exchange_rate = 1.0 };
}

test "insert picks columns by kind; duplicates match within ten days" {
    const db = try testDb();
    defer db.close();
    const buy = try insert(db, entry("buy", 1, 2_000_000, 10000, "2024-03-04"));
    _ = try insert(db, entry("dividend", 1, f.quantity_scale, 120, "2024-03-10"));
    _ = try insert(db, entry("deposit", null, f.quantity_scale, 50000, "2024-03-01"));

    var st = try db.prepare("SELECT quantity IS NULL, security IS NULL FROM \"transaction\" ORDER BY id");
    defer st.finalize();
    for ([_][2]i64{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 } }) |want| {
        _ = try st.step();
        try std.testing.expectEqual(want[0], st.int(0));
        try std.testing.expectEqual(want[1], st.int(1));
    }

    try std.testing.expectEqual(@as(?i64, buy), try findDuplicate(db, entry("buy", 1, 2_000_000, 10000, "2024-03-12")));
    try std.testing.expectEqual(@as(?i64, null), try findDuplicate(db, entry("buy", 1, 2_000_000, 10000, "2024-03-20")));
    try std.testing.expectEqual(@as(?i64, null), try findDuplicate(db, entry("buy", 1, 3_000_000, 10000, "2024-03-04")));
    try std.testing.expect(try findDuplicate(db, entry("deposit", null, f.quantity_scale, 50000, "2024-03-02")) != null);
}

test "holdings exclude the recorded copy of a sell" {
    const db = try testDb();
    defer db.close();
    _ = try insert(db, entry("buy", 1, 5_000_000, 500, "2024-01-01"));
    const sell = try insert(db, entry("sell", 1, 2_000_000, 300, "2024-02-01"));
    try std.testing.expectEqual(@as(i64, 3_000_000), try holdings(db, 1, 1, null));
    try std.testing.expectEqual(@as(i64, 5_000_000), try holdings(db, 1, 1, sell));
}

test "securities by ISIN, creation and name filling" {
    const db = try testDb();
    defer db.close();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(?i64, 1), try securityByIsin(db, "US0378331005"));
    try std.testing.expectEqual(@as(?i64, null), try securityByIsin(db, "DE0007164600"));
    try std.testing.expectEqual(@as(?i64, null), try securityByIsin(db, "IE00B4L5Y983"));
    const id = try addSecurity(db, "IE00B4L5Y983", "World ETF");
    try std.testing.expectEqual(@as(?i64, id), try securityByIsin(db, "IE00B4L5Y983"));

    try fillSecurityName(db, 1, "Example Inc.");
    try fillSecurityName(db, 2, "Overwritten?");
    try std.testing.expectEqualStrings("Example Inc.", (try security(db, arena.allocator(), 1)).?.name);
    try std.testing.expectEqualStrings("SAP", (try security(db, arena.allocator(), 2)).?.name);
    try std.testing.expect(try security(db, arena.allocator(), 99) == null);
}
