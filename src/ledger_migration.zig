//! Moves the single-entry `transaction` rows into the double-entry journal
//! (docs/ledger-model.md, "Migration"). Rows already migrated are skipped, so
//! it can run again while both models exist.

const std = @import("std");
const Allocator = std.mem.Allocator;

const bookings = @import("bookings.zig");
const sqlite = @import("sqlite.zig");

pub const Summary = struct {
    migrated: usize = 0,
    already: usize = 0,
    documents: usize = 0,
    /// Dividends whose old `cost` was booked as KapESt: the old model does not
    /// say which tax it was.
    dividend_costs_as_kapest: usize = 0,
};

const Old = struct {
    id: i64,
    account: []const u8,
    security: ?i64,
    kind: []const u8,
    total: i64,
    quantity: ?i64,
    cost: i64,
    date: []const u8,
    linked: ?i64,
    currency: []const u8,
    rate: f64,
};

fn eur(cents: i64, rate: f64) i64 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(cents)) * rate));
}

/// Within the caller's database transaction.
pub fn migrate(b: bookings.Book) !Summary {
    var rows: std.ArrayList(Old) = .empty;
    {
        var st = try b.db.prepare(
            \\SELECT t.id, a.name, t.security, t.type, COALESCE(t.total_value, 0), t.quantity,
            \\       COALESCE(t.cost, 0), t.date, t.linked_transaction, COALESCE(t.currency, 'EUR'),
            \\       COALESCE(NULLIF(t.exchange_rate, 0), 1.0)
            \\FROM "transaction" t JOIN account a ON a.id = t.account
            \\ORDER BY t.date, t.id
        );
        defer st.finalize();
        while (try st.step()) try rows.append(b.a, .{
            .id = st.int(0),
            .account = (try st.text(b.a, 1)).?,
            .security = st.optInt(2),
            .kind = (try st.text(b.a, 3)) orelse "",
            .total = st.int(4),
            .quantity = st.optInt(5),
            .cost = st.int(6),
            .date = (try st.text(b.a, 7)).?,
            .linked = st.optInt(8),
            .currency = (try st.text(b.a, 9)).?,
            .rate = st.float(10),
        });
    }

    var sum: Summary = .{};
    for (rows.items) |r| {
        if (try mapped(b, r.id) != null) {
            sum.already += 1;
            continue;
        }
        const txn = try book(b, rows.items, r, &sum);
        try b.db.run("INSERT INTO migrated_transaction (old, txn) VALUES (?, ?)", .{ r.id, txn });
        if (r.linked) |partner| if (std.mem.eql(u8, r.kind, "transfer"))
            try b.db.run("INSERT OR IGNORE INTO migrated_transaction (old, txn) VALUES (?, ?)", .{ partner, txn });
        sum.migrated += 1;
    }

    const before = try count(b, "SELECT COUNT(*) FROM txn_document");
    try b.db.exec(
        \\INSERT OR IGNORE INTO txn_document (txn, paperless_id)
        \\SELECT m.txn, d.paperless_id FROM transaction_document d
        \\JOIN migrated_transaction m ON m.old = d.transaction_id
    );
    sum.documents = @intCast(try count(b, "SELECT COUNT(*) FROM txn_document") - before);
    return sum;
}

fn count(b: bookings.Book, sql: []const u8) !i64 {
    var st = try b.db.prepare(sql);
    defer st.finalize();
    _ = try st.step();
    return st.int(0);
}

fn mapped(b: bookings.Book, old: i64) !?i64 {
    var st = try b.db.prepare("SELECT txn FROM migrated_transaction WHERE old = ?");
    defer st.finalize();
    try st.bindAll(.{old});
    return if (try st.step()) st.int(0) else null;
}

fn book(b: bookings.Book, rows: []const Old, r: Old, sum: *Summary) !i64 {
    const eq = std.mem.eql;
    const total = eur(r.total, r.rate);
    if (eq(u8, r.kind, "buy") or eq(u8, r.kind, "sell")) {
        const t: bookings.Trade = .{ .date = r.date, .security = r.security.?, .quantity = r.quantity.?, .total = total, .fees = r.cost };
        return if (eq(u8, r.kind, "buy")) bookings.buy(b, r.account, t) else bookings.sell(b, r.account, t);
    }
    if (eq(u8, r.kind, "dividend")) {
        if (r.cost != 0) sum.dividend_costs_as_kapest += 1;
        return bookings.dividend(b, r.account, .{
            .date = r.date,
            .security = r.security.?,
            .gross = total,
            .taxes = .{ .kapest = r.cost },
            .currency = r.currency,
            .original = if (eq(u8, r.currency, "EUR")) null else r.total,
        });
    }
    const id = if (eq(u8, r.kind, "deposit"))
        try bookings.deposit(b, r.account, r.date, total)
    else if (eq(u8, r.kind, "withdrawal"))
        try bookings.withdrawal(b, r.account, r.date, total)
    else if (eq(u8, r.kind, "interest"))
        try bookings.interest(b, r.account, r.date, total)
    else if (eq(u8, r.kind, "transfer"))
        try transfer(b, rows, r, total)
    else
        return error.UnknownType;
    // Costs on these rows were fees charged alongside.
    if (r.cost != 0) _ = try bookings.fee(b, r.account, r.date, r.cost);
    return id;
}

/// Old transfers are two linked rows; the negative one is the source.
fn transfer(b: bookings.Book, rows: []const Old, r: Old, total: i64) !i64 {
    const partner = for (rows) |o| {
        if (o.id == r.linked) break o;
    } else return error.UnlinkedTransfer;
    const from, const to = if (total < 0) .{ r.account, partner.account } else .{ partner.account, r.account };
    return bookings.transfer(b, from, to, r.date, @intCast(@abs(total)));
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "old rows become balanced transactions with lots and documents" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b = try bookings.testBook(arena.allocator(), .{ .owner = "Name" });
    defer b.db.close();
    try b.db.exec(
        \\INSERT INTO account (name) VALUES ('Scalable'), ('Bank');
        \\INSERT INTO security (isin, name, type) VALUES ('US0378331005', 'Example Inc.', 'stock');
        \\INSERT INTO "transaction" (id, account, security, type, quantity, unit_value, total_value, cost, date, linked_transaction, currency, exchange_rate) VALUES
        \\  (1, 1, NULL, 'deposit', NULL, NULL, 500000, 0, '2024-01-01', NULL, 'EUR', 1.0),
        \\  (2, 1, 1, 'buy', 10000000, 10000, 100000, 100, '2024-01-10', NULL, 'EUR', 1.0),
        \\  (3, 1, 1, 'dividend', NULL, NULL, 1240, 290, '2024-03-17', NULL, 'USD', 0.9145),
        \\  (4, 1, 1, 'sell', 4000000, 13000, 52000, 100, '2024-04-01', NULL, 'EUR', 1.0),
        \\  (5, 1, NULL, 'transfer', NULL, NULL, -20000, 50, '2024-05-01', 6, 'EUR', 1.0),
        \\  (6, 2, NULL, 'transfer', NULL, NULL, 20000, 0, '2024-05-01', 5, 'EUR', 1.0),
        \\  (7, 1, NULL, 'interest', NULL, NULL, 250, 0, '2024-06-30', NULL, 'EUR', 1.0),
        \\  (8, 1, NULL, 'withdrawal', NULL, NULL, 10000, 0, '2024-07-01', NULL, 'EUR', 1.0);
        \\INSERT INTO transaction_document (transaction_id, paperless_id) VALUES (2, 158), (4, 159), (5, 300), (6, 300);
    );
    const s = try migrate(b);
    try testing.expectEqual(@as(usize, 7), s.migrated);
    try testing.expectEqual(@as(usize, 1), s.already);
    try testing.expectEqual(@as(usize, 3), s.documents);
    try testing.expectEqual(@as(usize, 1), s.dividend_costs_as_kapest);

    const bal = bookings.balance;
    // 5000 − 1001 + (11.34 − 2.90) + (520 − 1) − 200 − 0.50 fee + 2.50 − 100
    try testing.expectEqual(@as(i64, 500000 - 100100 + (1134 - 290) + (52000 - 100) - 20000 - 50 + 250 - 10000), try bal(b, "Assets:Scalable:Cash"));
    try testing.expectEqual(@as(i64, 20000), try bal(b, "Assets:Bank:Cash"));
    try testing.expectEqual(@as(i64, 100100 - 40040), try bal(b, "Assets:Scalable:Depot"));
    try testing.expectEqual(@as(i64, -(51900 - 40040)), try bal(b, "Income:Gains:Shares"));
    try testing.expectEqual(@as(i64, -1134), try bal(b, "Income:Dividends"));
    try testing.expectEqual(@as(i64, 290), try bal(b, "Expenses:Tax:KapESt"));
    try testing.expectEqual(@as(i64, 50), try bal(b, "Expenses:Fees"));
    try testing.expectEqual(@as(i64, 6 * 1_000_000), try bookings.held(b, "Scalable", 1));

    // Everything balances overall.
    var st = try b.db.prepare("SELECT COALESCE(SUM(amount), 0), COUNT(DISTINCT txn) FROM posting");
    defer st.finalize();
    _ = try st.step();
    try testing.expectEqual(@as(i64, 0), st.int(0));
    try testing.expectEqual(@as(i64, 8), st.int(1));

    // A second run finds nothing new.
    const again = try migrate(b);
    try testing.expectEqual(@as(usize, 0), again.migrated);
    try testing.expectEqual(@as(usize, 8), again.already);
}
