//! Port of migrations.py: schema migrations keyed on PRAGMA user_version.
//! Each step is idempotent, so fresh and already-migrated databases both work.

const std = @import("std");
const sqlite = @import("sqlite.zig");

fn version(db: sqlite.Db) !i64 {
    var st = try db.prepare("PRAGMA user_version");
    defer st.finalize();
    _ = try st.step();
    return st.int(0);
}

fn hasColumn(db: sqlite.Db, table: []const u8, column: []const u8) !bool {
    var buf: [128]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buf, "PRAGMA table_info(\"{s}\")", .{table});
    var st = try db.prepare(sql);
    defer st.finalize();
    while (try st.step()) {
        var name_buf: [256]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&name_buf);
        const name = (try st.text(fba.allocator(), 1)) orelse continue;
        if (std.mem.eql(u8, name, column)) return true;
    }
    return false;
}

fn m001(db: sqlite.Db) !void {
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS "index" (
        \\    id INTEGER PRIMARY KEY ASC,
        \\    name TEXT,
        \\    url TEXT
        \\);
        \\CREATE TABLE IF NOT EXISTS company (
        \\    id INTEGER PRIMARY KEY ASC,
        \\    isin TEXT,
        \\    name TEXT,
        \\    url TEXT
        \\);
        \\CREATE TABLE IF NOT EXISTS raw_html (
        \\    id INTEGER PRIMARY KEY ASC,
        \\    com INTEGER,
        \\    html TEXT,
        \\    timestamp TEXT,
        \\    FOREIGN KEY (com) REFERENCES company (id) ON DELETE CASCADE
        \\);
        \\CREATE TABLE IF NOT EXISTS account (
        \\    id INTEGER PRIMARY KEY ASC,
        \\    name TEXT NOT NULL UNIQUE
        \\);
        \\CREATE TABLE IF NOT EXISTS "transaction" (
        \\    id INTEGER PRIMARY KEY ASC,
        \\    account INTEGER NOT NULL REFERENCES account (id),
        \\    company INTEGER REFERENCES company (id),
        \\    type TEXT CHECK (type IN (
        \\        'buy',
        \\        'sell',
        \\        'dividend',
        \\        'interest',
        \\        'deposit',
        \\        'withdrawal',
        \\        'transfer'
        \\    )),
        \\    total_value INTEGER,
        \\    unit_value INTEGER,
        \\    quantity INTEGER,
        \\    cost INTEGER,
        \\    date DATE NOT NULL,
        \\    linked_transaction INTEGER REFERENCES "transaction" (id),
        \\    FOREIGN KEY (company) REFERENCES company (id) ON DELETE CASCADE
        \\);
    );
}

fn m002(db: sqlite.Db) !void {
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS transaction_document (
        \\    id INTEGER PRIMARY KEY ASC,
        \\    transaction_id INTEGER NOT NULL REFERENCES "transaction" (id) ON DELETE CASCADE,
        \\    paperless_id INTEGER NOT NULL,
        \\    UNIQUE(transaction_id, paperless_id)
        \\);
    );
}

fn m003(db: sqlite.Db) !void {
    if (!try hasColumn(db, "transaction", "currency"))
        try db.exec("ALTER TABLE \"transaction\" ADD COLUMN currency TEXT DEFAULT 'EUR'");
    if (!try hasColumn(db, "transaction", "exchange_rate"))
        try db.exec("ALTER TABLE \"transaction\" ADD COLUMN exchange_rate REAL DEFAULT 1.0");
}

fn m004(db: sqlite.Db) !void {
    try db.exec("ALTER TABLE company RENAME TO security");
    if (!try hasColumn(db, "security", "type"))
        try db.exec("ALTER TABLE security ADD COLUMN type TEXT DEFAULT 'stock'");
    try db.exec("ALTER TABLE \"transaction\" RENAME COLUMN company TO security");
    try db.exec("DROP TABLE IF EXISTS raw_html");
    try db.exec("DROP TABLE IF EXISTS \"index\"");
}

/// Quantities move to millionths of a share, so savings-plan fractions fit.
fn m005(db: sqlite.Db) !void {
    try db.exec("UPDATE \"transaction\" SET quantity = quantity * 1000000 WHERE quantity IS NOT NULL");
}

/// Double-entry tables (docs/ledger-model.md), empty until the old rows are migrated.
fn m006(db: sqlite.Db) !void {
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS person (
        \\    id INTEGER PRIMARY KEY,
        \\    name TEXT NOT NULL UNIQUE
        \\);
        \\CREATE TABLE IF NOT EXISTS ledger_account (
        \\    id INTEGER PRIMARY KEY,
        \\    name TEXT NOT NULL UNIQUE,
        \\    kind TEXT NOT NULL CHECK (kind IN ('asset', 'liability', 'equity', 'income', 'expense')),
        \\    owner INTEGER REFERENCES person (id),
        \\    CHECK (owner IS NOT NULL OR kind NOT IN ('asset', 'liability'))
        \\);
        \\CREATE TABLE IF NOT EXISTS txn (
        \\    id INTEGER PRIMARY KEY,
        \\    date DATE NOT NULL,
        \\    description TEXT NOT NULL DEFAULT ''
        \\);
        \\CREATE TABLE IF NOT EXISTS posting (
        \\    id INTEGER PRIMARY KEY,
        \\    txn INTEGER NOT NULL REFERENCES txn (id) ON DELETE CASCADE,
        \\    account INTEGER NOT NULL REFERENCES ledger_account (id),
        \\    amount INTEGER NOT NULL,
        \\    currency TEXT NOT NULL DEFAULT 'EUR',
        \\    original INTEGER,
        \\    security INTEGER REFERENCES security (id),
        \\    quantity INTEGER,
        \\    CHECK ((security IS NULL) = (quantity IS NULL))
        \\);
        \\CREATE INDEX IF NOT EXISTS posting_txn ON posting (txn);
        \\CREATE INDEX IF NOT EXISTS posting_account ON posting (account);
        \\CREATE TABLE IF NOT EXISTS lot (
        \\    id INTEGER PRIMARY KEY,
        \\    account INTEGER NOT NULL REFERENCES ledger_account (id),
        \\    security INTEGER NOT NULL REFERENCES security (id),
        \\    txn INTEGER NOT NULL REFERENCES txn (id),
        \\    opened DATE NOT NULL,
        \\    quantity INTEGER NOT NULL,
        \\    cost INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS lot_close (
        \\    id INTEGER PRIMARY KEY,
        \\    lot INTEGER NOT NULL REFERENCES lot (id),
        \\    txn INTEGER NOT NULL REFERENCES txn (id),
        \\    quantity INTEGER NOT NULL,
        \\    cost INTEGER NOT NULL,
        \\    proceeds INTEGER NOT NULL
        \\);
        \\CREATE TABLE IF NOT EXISTS price (
        \\    security INTEGER NOT NULL REFERENCES security (id),
        \\    date DATE NOT NULL,
        \\    price INTEGER NOT NULL,
        \\    currency TEXT NOT NULL DEFAULT 'EUR',
        \\    source TEXT NOT NULL,
        \\    PRIMARY KEY (security, date, source)
        \\);
        \\CREATE TABLE IF NOT EXISTS txn_document (
        \\    txn INTEGER NOT NULL REFERENCES txn (id) ON DELETE CASCADE,
        \\    paperless_id INTEGER NOT NULL,
        \\    PRIMARY KEY (txn, paperless_id)
        \\);
    );
}

const steps = [_]*const fn (sqlite.Db) anyerror!void{ m001, m002, m003, m004, m005, m006 };

pub fn run(db: sqlite.Db) !void {
    const current = try version(db);
    var i: usize = @intCast(current);
    while (i < steps.len) : (i += 1) {
        try db.exec("BEGIN");
        errdefer db.exec("ROLLBACK") catch {};
        try steps[i](db);
        var buf: [64]u8 = undefined;
        try db.exec(try std.fmt.bufPrintSentinel(&buf, "PRAGMA user_version = {d}", .{i + 1}, 0));
        try db.exec("COMMIT");
    }
}

test "fresh database migrates to the current schema" {
    const db = try sqlite.Db.open(":memory:");
    defer db.close();
    try run(db);
    try std.testing.expectEqual(@as(i64, 6), try version(db));
    try std.testing.expect(try hasColumn(db, "transaction", "security"));
    try std.testing.expect(try hasColumn(db, "transaction", "exchange_rate"));
    try std.testing.expect(try hasColumn(db, "security", "type"));
    try run(db); // idempotent
}

test "v5 scales existing quantities to millionths once" {
    const db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.exec("PRAGMA user_version = 0");
    try db.exec("BEGIN");
    try m001(db);
    try m002(db);
    try m003(db);
    try m004(db);
    try db.exec("PRAGMA user_version = 4");
    try db.exec("COMMIT");
    try db.exec("INSERT INTO account (name) VALUES ('A')");
    try db.exec("INSERT INTO \"transaction\" (account, type, quantity, unit_value, total_value, date) VALUES (1, 'buy', 3, 100, 300, '2024-01-01')");
    try db.exec("INSERT INTO \"transaction\" (account, type, total_value, date) VALUES (1, 'deposit', 500, '2024-01-01')");
    try run(db);
    try run(db);
    var st = try db.prepare("SELECT quantity FROM \"transaction\" ORDER BY id");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 3_000_000), st.int(0));
    _ = try st.step();
    try std.testing.expect(st.isNull(0));
}

test "v6 constraints: asset accounts need an owner, postings pair security and quantity" {
    const db = try sqlite.Db.open(":memory:");
    defer db.close();
    try run(db);
    try db.exec("PRAGMA foreign_keys = ON;");
    try db.exec("INSERT INTO person (name) VALUES ('Name')");
    try db.exec("INSERT INTO ledger_account (name, kind, owner) VALUES ('Assets:Cash', 'asset', 1)");
    try db.exec("INSERT INTO ledger_account (name, kind) VALUES ('Income:Dividends', 'income')");
    try std.testing.expectError(error.Constraint, db.exec("INSERT INTO ledger_account (name, kind) VALUES ('Assets:Depot', 'asset')"));
    try std.testing.expectError(error.Constraint, db.exec("INSERT INTO ledger_account (name, kind, owner) VALUES ('Other:X', 'other', 1)"));
    try db.exec("INSERT INTO txn (date) VALUES ('2024-01-01')");
    try std.testing.expectError(error.Constraint, db.exec("INSERT INTO posting (txn, account, amount, quantity) VALUES (1, 1, 100, 5)"));
    try std.testing.expectError(error.Constraint, db.exec("INSERT INTO posting (txn, account, amount) VALUES (1, 99, 100)"));
}
