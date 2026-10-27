//! Double-entry journal: accounts with a kind and an owner, and transactions
//! whose postings sum to zero (docs/ledger-model.md).

const std = @import("std");
const assert = std.debug.assert;
const sqlite = @import("sqlite.zig");

pub const Kind = enum { asset, liability, equity, income, expense };

/// Top-level account names; the top level decides an account's kind.
pub const Roots = struct {
    assets: []const u8 = "Assets",
    liabilities: []const u8 = "Liabilities",
    equity: []const u8 = "Equity",
    income: []const u8 = "Income",
    expenses: []const u8 = "Expenses",
};

/// The kind of a full account name like "Expenses:Tax:KapESt"; null when the
/// top level is not one of `roots` or a segment is empty.
pub fn kindOf(name: []const u8, roots: Roots) ?Kind {
    var it = std.mem.splitScalar(u8, name, ':');
    const top = it.first();
    var segments: usize = 1;
    while (it.next()) |seg| : (segments += 1) if (seg.len == 0) return null;
    if (segments < 2 or top.len == 0) return null;
    const pairs = [_]struct { []const u8, Kind }{
        .{ roots.assets, .asset },  .{ roots.liabilities, .liability }, .{ roots.equity, .equity },
        .{ roots.income, .income }, .{ roots.expenses, .expense },
    };
    for (pairs) |p| if (std.mem.eql(u8, top, p[0])) return p[1];
    return null;
}

pub const Account = struct { id: i64, kind: Kind, owner: ?i64 };

pub const Error = error{
    TooFewPostings,
    Unbalanced,
    MixedOwners,
    UnknownAccount,
    InvalidAccountName,
    OwnerRequired,
    InvalidPosting,
} || sqlite.Error;

pub fn createPerson(db: sqlite.Db, name: []const u8) Error!i64 {
    try db.run("INSERT INTO person (name) VALUES (?)", .{name});
    return db.lastInsertRowId();
}

/// Asset and liability accounts need an owner; others take none.
pub fn createAccount(db: sqlite.Db, name: []const u8, roots: Roots, owner: ?i64) Error!i64 {
    const kind = kindOf(name, roots) orelse return error.InvalidAccountName;
    const owned = kind == .asset or kind == .liability;
    if (owned and owner == null) return error.OwnerRequired;
    try db.run("INSERT INTO ledger_account (name, kind, owner) VALUES (?, ?, ?)", .{ name, @tagName(kind), if (owned) owner else null });
    return db.lastInsertRowId();
}

pub fn accountByName(db: sqlite.Db, name: []const u8) Error!?Account {
    var st = try db.prepare("SELECT id FROM ledger_account WHERE name = ?");
    defer st.finalize();
    try st.bindAll(.{name});
    if (!try st.step()) return null;
    return try account(db, st.int(0));
}

pub fn account(db: sqlite.Db, id: i64) Error!?Account {
    var st = try db.prepare("SELECT kind, owner FROM ledger_account WHERE id = ?");
    defer st.finalize();
    try st.bindAll(.{id});
    if (!try st.step()) return null;
    return .{
        .id = id,
        .kind = std.meta.stringToEnum(Kind, st.textRef(0) orelse "") orelse unreachable,
        .owner = st.optInt(1),
    };
}

pub const Posting = struct {
    account: i64,
    /// EUR cents; the postings of a transaction sum to zero.
    amount: i64,
    currency: []const u8 = "EUR",
    /// Cents in `currency` when it is not EUR.
    original: ?i64 = null,
    security: ?i64 = null,
    /// Millionths of a share, together with `security`.
    quantity: ?i64 = null,
};

pub const Txn = struct {
    /// ISO date.
    date: []const u8,
    description: []const u8 = "",
    postings: []const Posting,
};

/// Rejects what the schema cannot express: an unbalanced transaction, or one
/// touching several owners' asset and liability accounts.
pub fn validate(db: sqlite.Db, t: Txn) Error!void {
    if (t.postings.len < 2) return error.TooFewPostings;
    var sum: i64 = 0;
    var owner: ?i64 = null;
    for (t.postings) |p| {
        if ((p.security == null) != (p.quantity == null)) return error.InvalidPosting;
        if (p.quantity) |q| if (q == 0) return error.InvalidPosting;
        if (!std.mem.eql(u8, p.currency, "EUR") and p.original == null) return error.InvalidPosting;
        sum = std.math.add(i64, sum, p.amount) catch return error.Unbalanced;
        const acc = (try account(db, p.account)) orelse return error.UnknownAccount;
        if (acc.owner) |o| {
            if (owner) |prev| if (prev != o) return error.MixedOwners;
            owner = o;
        }
    }
    if (sum != 0) return error.Unbalanced;
}

/// Within the caller's database transaction; returns the new txn id.
pub fn insert(db: sqlite.Db, t: Txn) Error!i64 {
    try validate(db, t);
    try db.run("INSERT INTO txn (date, description) VALUES (?, ?)", .{ t.date, t.description });
    const id = db.lastInsertRowId();
    for (t.postings) |p| try db.run(
        \\INSERT INTO posting (txn, account, amount, currency, original, security, quantity)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    , .{ id, p.account, p.amount, p.currency, p.original, p.security, p.quantity });
    try assertBalanced(db, id);
    return id;
}

/// What `validate` promised is what got stored.
pub fn assertBalanced(db: sqlite.Db, id: i64) Error!void {
    var st = try db.prepare("SELECT COUNT(*), COALESCE(SUM(amount), 0) FROM posting WHERE txn = ?");
    defer st.finalize();
    try st.bindAll(.{id});
    assert(try st.step());
    assert(st.int(0) >= 2);
    assert(st.int(1) == 0);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn testDb() !sqlite.Db {
    const db = try sqlite.Db.open(":memory:");
    try @import("migrations.zig").run(db);
    try db.exec("PRAGMA foreign_keys = ON;");
    return db;
}

test "kinds come from the top level" {
    try testing.expectEqual(Kind.expense, kindOf("Expenses:Tax:KapESt", .{}).?);
    try testing.expectEqual(Kind.asset, kindOf("Assets:Name:Scalable:Cash", .{}).?);
    try testing.expect(kindOf("Assets", .{}) == null);
    try testing.expect(kindOf("Assets::Cash", .{}) == null);
    try testing.expect(kindOf("Expense:Fees", .{}) == null);
    try testing.expect(kindOf(":Fees", .{}) == null);
    try testing.expectEqual(Kind.expense, kindOf("Aufwand:Gebühren", .{ .expenses = "Aufwand" }).?);
}

test "accounts: owners for assets and liabilities only" {
    const db = try testDb();
    defer db.close();
    const owner = try createPerson(db, "Name");
    const cash = try createAccount(db, "Assets:Name:Cash", .{}, owner);
    const fees = try createAccount(db, "Expenses:Fees", .{}, owner);
    try testing.expectError(error.OwnerRequired, createAccount(db, "Assets:Name:Depot", .{}, null));
    try testing.expectError(error.InvalidAccountName, createAccount(db, "Fees", .{}, null));
    try testing.expectError(error.Constraint, createAccount(db, "Assets:Name:Cash", .{}, owner));
    try testing.expectEqual(Account{ .id = cash, .kind = .asset, .owner = owner }, (try accountByName(db, "Assets:Name:Cash")).?);
    try testing.expectEqual(@as(?i64, null), (try account(db, fees)).?.owner);
    try testing.expect(try accountByName(db, "Assets:Nope") == null);
}

test "transactions must balance and stay with one owner" {
    const db = try testDb();
    defer db.close();
    const owner = try createPerson(db, "Name");
    const other = try createPerson(db, "Other");
    const cash = try createAccount(db, "Assets:Name:Cash", .{}, owner);
    const depot = try createAccount(db, "Assets:Name:Depot", .{}, owner);
    const theirs = try createAccount(db, "Assets:Other:Cash", .{}, other);
    const fees = try createAccount(db, "Expenses:Fees", .{}, null);
    try db.exec("INSERT INTO security (isin, name) VALUES ('IE00B4L5Y983', 'World ETF')");

    const buy = try insert(db, .{ .date = "2024-03-04", .description = "buy", .postings = &.{
        .{ .account = depot, .amount = 100000, .security = 1, .quantity = 10_000_000 },
        .{ .account = fees, .amount = 100 },
        .{ .account = cash, .amount = -100100 },
    } });
    try testing.expect(buy > 0);

    try testing.expectError(error.Unbalanced, insert(db, .{ .date = "2024-03-05", .postings = &.{
        .{ .account = cash, .amount = 100 }, .{ .account = fees, .amount = -99 },
    } }));
    try testing.expectError(error.TooFewPostings, insert(db, .{ .date = "2024-03-05", .postings = &.{
        .{ .account = cash, .amount = 0 },
    } }));
    try testing.expectError(error.MixedOwners, insert(db, .{ .date = "2024-03-05", .postings = &.{
        .{ .account = cash, .amount = -500 }, .{ .account = theirs, .amount = 500 },
    } }));
    try testing.expectError(error.UnknownAccount, insert(db, .{ .date = "2024-03-05", .postings = &.{
        .{ .account = cash, .amount = -500 }, .{ .account = 99, .amount = 500 },
    } }));
    try testing.expectError(error.InvalidPosting, insert(db, .{ .date = "2024-03-05", .postings = &.{
        .{ .account = depot, .amount = 500, .security = 1 }, .{ .account = cash, .amount = -500 },
    } }));
    try testing.expectError(error.InvalidPosting, insert(db, .{ .date = "2024-03-05", .postings = &.{
        .{ .account = cash, .amount = 500, .currency = "USD" }, .{ .account = fees, .amount = -500 },
    } }));

    var st = try db.prepare("SELECT COUNT(*) FROM txn");
    defer st.finalize();
    _ = try st.step();
    try testing.expectEqual(@as(i64, 1), st.int(0));
}
