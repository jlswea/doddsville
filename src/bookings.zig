//! The shortcuts (`dv add buy …`, parser results) as journal transactions,
//! booked to the accounts named in `config.zon`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("Config.zig");
const journal = @import("journal.zig");
const sqlite = @import("sqlite.zig");

pub const Error = error{ NotPositive, InsufficientHolding, UnknownSecurity } || journal.Error || Allocator.Error;

pub const Broker = struct { cash: i64, depot: i64, owner: i64 };

pub const Book = struct {
    db: sqlite.Db,
    a: Allocator,
    ledger: Config.Ledger,
    /// Id for the next booked transaction; the database picks one when null.
    id: ?i64 = null,

    pub fn person(b: Book, name: []const u8) Error!i64 {
        var st = try b.db.prepare("SELECT id FROM person WHERE name = ?");
        defer st.finalize();
        try st.bindAll(.{name});
        if (try st.step()) return st.int(0);
        return journal.createPerson(b.db, name);
    }

    /// Accounts named in config.zon count as confirmed, so they are created
    /// on first use.
    pub fn ensure(b: Book, name: []const u8, owner: ?i64) Error!i64 {
        if (try journal.accountByName(b.db, name)) |acc| return acc.id;
        const kind = journal.kindOf(name, b.ledger.roots) orelse return error.InvalidAccountName;
        return journal.createAccount(b.db, name, b.ledger.roots, if (kind == .asset or kind == .liability) owner else null);
    }

    pub fn broker(b: Book, name: []const u8) Error!Broker {
        const cfg = try b.ledger.broker(b.a, name);
        const owner = try b.person(cfg.owner.?);
        return .{
            .cash = try b.ensure(cfg.cash.?, owner),
            .depot = try b.ensure(cfg.depot.?, owner),
            .owner = owner,
        };
    }

    fn role(b: Book, name: []const u8) Error!i64 {
        return b.ensure(name, null);
    }
};

fn positive(cents: i64) Error!void {
    if (cents <= 0) return error.NotPositive;
}

/// Money from outside the ledger, e.g. a transfer from a bank not tracked here.
pub fn deposit(b: Book, broker: []const u8, date: []const u8, cents: i64) Error!i64 {
    try positive(cents);
    const acc = try b.broker(broker);
    return journal.insert(b.db, .{ .id = b.id, .date = date, .description = "deposit", .postings = &.{
        .{ .account = acc.cash, .amount = cents },
        .{ .account = try b.role(b.ledger.accounts.contributions), .amount = -cents },
    } });
}

pub fn withdrawal(b: Book, broker: []const u8, date: []const u8, cents: i64) Error!i64 {
    try positive(cents);
    const acc = try b.broker(broker);
    return journal.insert(b.db, .{ .id = b.id, .date = date, .description = "withdrawal", .postings = &.{
        .{ .account = acc.cash, .amount = -cents },
        .{ .account = try b.role(b.ledger.accounts.contributions), .amount = cents },
    } });
}

pub fn interest(b: Book, broker: []const u8, date: []const u8, cents: i64) Error!i64 {
    try positive(cents);
    const acc = try b.broker(broker);
    return journal.insert(b.db, .{ .id = b.id, .date = date, .description = "interest", .postings = &.{
        .{ .account = acc.cash, .amount = cents },
        .{ .account = try b.role(b.ledger.accounts.interest), .amount = -cents },
    } });
}

/// A fee not tied to a trade, e.g. custody fees; trade fees are part of the
/// trade's cost or proceeds.
pub fn fee(b: Book, broker: []const u8, date: []const u8, cents: i64) Error!i64 {
    try positive(cents);
    const acc = try b.broker(broker);
    return journal.insert(b.db, .{ .id = b.id, .date = date, .description = "fee", .postings = &.{
        .{ .account = try b.role(b.ledger.accounts.fees), .amount = cents },
        .{ .account = acc.cash, .amount = -cents },
    } });
}

/// Withheld or refunded taxes in cents; refunds book these as negative expenses.
pub const Taxes = struct {
    kapest: i64 = 0,
    soli: i64 = 0,
    kist: i64 = 0,
    quellensteuer: i64 = 0,

    pub fn total(t: Taxes) i64 {
        return t.kapest + t.soli + t.kist + t.quellensteuer;
    }
};

pub fn taxRefund(b: Book, broker: []const u8, date: []const u8, refund: Taxes) Error!i64 {
    try positive(refund.total());
    const acc = try b.broker(broker);
    var postings: std.ArrayList(journal.Posting) = .empty;
    try postings.append(b.a, .{ .account = acc.cash, .amount = refund.total() });
    try appendTaxes(b, &postings, refund, -1);
    return journal.insert(b.db, .{ .id = b.id, .date = date, .description = "tax refund", .postings = postings.items });
}

fn appendTaxes(b: Book, postings: *std.ArrayList(journal.Posting), t: Taxes, sign: i64) Error!void {
    const parts = [_]struct { i64, []const u8 }{
        .{ t.kapest, b.ledger.accounts.kapest },
        .{ t.soli, b.ledger.accounts.soli },
        .{ t.kist, b.ledger.accounts.kist },
        .{ t.quellensteuer, b.ledger.accounts.quellensteuer },
    };
    for (parts) |part| {
        if (part[0] < 0) return error.NotPositive;
        if (part[0] > 0) try postings.append(b.a, .{ .account = try b.role(part[1]), .amount = sign * part[0] });
    }
}

/// Between two cash accounts of the same person.
pub fn transfer(b: Book, from: []const u8, to: []const u8, date: []const u8, cents: i64) Error!i64 {
    try positive(cents);
    const src = try b.broker(from);
    const dst = try b.broker(to);
    return journal.insert(b.db, .{ .id = b.id, .date = date, .description = "transfer", .postings = &.{
        .{ .account = src.cash, .amount = -cents },
        .{ .account = dst.cash, .amount = cents },
    } });
}

/// Runs `body` in a savepoint, so it nests inside the caller's transaction and
/// leaves nothing behind on error.
fn atomic(b: Book, comptime body: anytype, args: anytype) Error!i64 {
    try b.db.exec("SAVEPOINT booking");
    const id = @call(.auto, body, args) catch |err| {
        b.db.exec("ROLLBACK TO booking") catch {};
        b.db.exec("RELEASE booking") catch {};
        return err;
    };
    try b.db.exec("RELEASE booking");
    return id;
}

pub const Trade = struct {
    date: []const u8,
    security: i64,
    /// Millionths of a share.
    quantity: i64,
    /// Kurswert in cents.
    total: i64,
    /// Fees in cents: capitalised on a buy, deducted from the proceeds on a sell.
    fees: i64 = 0,
    /// Withheld on a sell.
    taxes: Taxes = .{},
};

/// Depot + Kurswert and + fees (a separate posting, so the fee stays visible),
/// cash − both, and a lot at their sum.
pub fn buy(b: Book, broker: []const u8, t: Trade) Error!i64 {
    return atomic(b, buyInner, .{ b, broker, t });
}

fn buyInner(b: Book, broker: []const u8, t: Trade) Error!i64 {
    try positive(t.quantity);
    try positive(t.total);
    if (t.fees < 0) return error.NotPositive;
    const acc = try b.broker(broker);
    const cost = std.math.add(i64, t.total, t.fees) catch return error.Unbalanced;
    var postings: std.ArrayList(journal.Posting) = .empty;
    try postings.append(b.a, .{ .account = acc.depot, .amount = t.total, .security = t.security, .quantity = t.quantity });
    if (t.fees > 0) try postings.append(b.a, .{ .account = acc.depot, .amount = t.fees, .security = t.security, .fee = true });
    try postings.append(b.a, .{ .account = acc.cash, .amount = -cost });
    const id = try journal.insert(b.db, .{ .id = b.id, .date = t.date, .description = "buy", .postings = postings.items });
    try b.db.run("INSERT INTO lot (account, security, txn, opened, quantity, cost) VALUES (?, ?, ?, ?, ?, ?)", .{ acc.depot, t.security, id, t.date, t.quantity, cost });
    return id;
}

const OpenLot = struct { id: i64, quantity: i64, cost: i64 };

/// Remaining quantity and cost of each lot, oldest first (FIFO).
fn openLots(b: Book, depot: i64, security: i64) Error![]OpenLot {
    var st = try b.db.prepare(
        \\SELECT l.id, l.quantity - COALESCE(SUM(c.quantity), 0), l.cost - COALESCE(SUM(c.cost), 0)
        \\FROM lot l LEFT JOIN lot_close c ON c.lot = l.id
        \\WHERE l.account = ? AND l.security = ?
        \\GROUP BY l.id HAVING l.quantity - COALESCE(SUM(c.quantity), 0) > 0
        \\ORDER BY l.opened, l.id
    );
    defer st.finalize();
    try st.bindAll(.{ depot, security });
    var out: std.ArrayList(OpenLot) = .empty;
    while (try st.step()) try out.append(b.a, .{ .id = st.int(0), .quantity = st.int(1), .cost = st.int(2) });
    return out.items;
}

fn mulDiv(x: i64, y: i64, z: i64) i64 {
    return @intCast(@divFloor(@as(i128, x) * y, z));
}

fn isShare(b: Book, security: i64) Error!bool {
    var st = try b.db.prepare("SELECT type FROM security WHERE id = ?");
    defer st.finalize();
    try st.bindAll(.{security});
    if (!try st.step()) return error.UnknownSecurity;
    return std.mem.eql(u8, st.textRef(0) orelse "stock", "stock");
}

/// Closes the oldest lots first. The gain is proceeds − fees − FIFO cost;
/// shares and everything else (funds, ETFs) go to separate gain accounts,
/// matching the separate loss pots.
pub fn sell(b: Book, broker: []const u8, t: Trade) Error!i64 {
    return atomic(b, sellInner, .{ b, broker, t });
}

fn sellInner(b: Book, broker: []const u8, t: Trade) Error!i64 {
    try positive(t.quantity);
    try positive(t.total);
    if (t.fees < 0) return error.NotPositive;
    const acc = try b.broker(broker);
    const taken = try fifo(b, acc.depot, t.security, t.quantity);

    const net = t.total - t.fees;
    const gain = net - taken.basis;
    var postings: std.ArrayList(journal.Posting) = .empty;
    try postings.append(b.a, .{ .account = acc.cash, .amount = net - t.taxes.total() });
    try appendTaxes(b, &postings, t.taxes, 1);
    try postings.append(b.a, .{ .account = acc.depot, .amount = -taken.basis, .security = t.security, .quantity = -t.quantity });
    const gains = try gainsAccount(b, t.security);
    if (gain + t.fees != 0) try postings.append(b.a, .{ .account = gains, .amount = -(gain + t.fees) });
    if (t.fees > 0) try postings.append(b.a, .{ .account = gains, .amount = t.fees, .fee = true });
    const id = try journal.insert(b.db, .{ .id = b.id, .date = t.date, .description = "sell", .postings = postings.items });
    try closeLots(b, id, taken.takes, t.quantity, net);
    return id;
}

fn gainsAccount(b: Book, security: i64) Error!i64 {
    return b.role(if (try isShare(b, security)) b.ledger.accounts.gains_shares else b.ledger.accounts.gains_other);
}

const Take = struct { lot: i64, quantity: i64, cost: i64 };
const Taken = struct { takes: []const Take, basis: i64 };

/// Takes `quantity` from the oldest open lots.
fn fifo(b: Book, depot: i64, security: i64, quantity: i64) Error!Taken {
    var takes: std.ArrayList(Take) = .empty;
    var left = quantity;
    var basis: i64 = 0;
    for (try openLots(b, depot, security)) |l| {
        if (left == 0) break;
        const q = @min(left, l.quantity);
        // The last piece of a lot takes its exact remaining cost.
        const c = if (q == l.quantity) l.cost else mulDiv(l.cost, q, l.quantity);
        try takes.append(b.a, .{ .lot = l.id, .quantity = q, .cost = c });
        basis += c;
        left -= q;
    }
    if (left > 0) return error.InsufficientHolding;
    return .{ .takes = takes.items, .basis = basis };
}

/// Records which lots a sale closed; the net proceeds are split by quantity.
fn closeLots(b: Book, txn: i64, takes: []const Take, quantity: i64, net: i64) Error!void {
    var proceeds_left = net;
    for (takes, 0..) |tk, i| {
        const part = if (i == takes.len - 1) proceeds_left else mulDiv(net, tk.quantity, quantity);
        proceeds_left -= part;
        try b.db.run("INSERT INTO lot_close (lot, txn, quantity, cost, proceeds) VALUES (?, ?, ?, ?, ?)", .{ tk.lot, txn, tk.quantity, tk.cost, part });
    }
}

/// Rebuilds the lots of `security` in `depot` from its trades in date order
/// and recomputes each sale's cost and gain, e.g. after an earlier trade was
/// corrected. Returns the sales whose gain changed.
pub fn replay(b: Book, depot: i64, security: i64) Error![]const i64 {
    try b.db.run("DELETE FROM lot_close WHERE lot IN (SELECT id FROM lot WHERE account = ? AND security = ?)", .{ depot, security });
    try b.db.run("DELETE FROM lot WHERE account = ? AND security = ?", .{ depot, security });

    const Trade_ = struct { txn: i64, date: []const u8, posting: i64, quantity: i64 };
    var trades: std.ArrayList(Trade_) = .empty;
    {
        var st = try b.db.prepare(
            \\SELECT t.id, t.date, p.id, p.quantity FROM posting p JOIN txn t ON t.id = p.txn
            \\WHERE p.account = ? AND p.security = ? AND p.quantity IS NOT NULL
            \\ORDER BY t.date, t.id, p.id
        );
        defer st.finalize();
        try st.bindAll(.{ depot, security });
        while (try st.step()) try trades.append(b.a, .{ .txn = st.int(0), .date = (try st.text(b.a, 1)).?, .posting = st.int(2), .quantity = st.int(3) });
    }

    const gain_names = [_][]const u8{ b.ledger.accounts.gains_shares, b.ledger.accounts.gains_other };
    var changed: std.ArrayList(i64) = .empty;
    for (trades.items) |tr| {
        if (tr.quantity > 0) {
            const cost = try sum(b, "SELECT SUM(amount) FROM posting WHERE txn = ? AND account = ? AND security = ?", .{ tr.txn, depot, security });
            try b.db.run("INSERT INTO lot (account, security, txn, opened, quantity, cost) VALUES (?, ?, ?, ?, ?, ?)", .{ depot, security, tr.txn, tr.date, tr.quantity, cost });
            continue;
        }
        const quantity = -tr.quantity;
        const taken = try fifo(b, depot, security, quantity);
        const in_gains = "account IN (SELECT id FROM ledger_account WHERE name IN (?, ?))";
        const net = try sum(b, "SELECT COALESCE(SUM(amount), 0) FROM posting WHERE txn = ? AND id != ? AND NOT " ++ in_gains, .{ tr.txn, tr.posting, gain_names[0], gain_names[1] });
        const fees = try sum(b, "SELECT COALESCE(SUM(amount), 0) FROM posting WHERE txn = ? AND fee AND " ++ in_gains, .{ tr.txn, gain_names[0], gain_names[1] });
        const amount = -(net - taken.basis + fees);

        try b.db.run("UPDATE posting SET amount = ? WHERE id = ?", .{ -taken.basis, tr.posting });
        var st = try b.db.prepare("SELECT id, amount FROM posting WHERE txn = ? AND NOT fee AND " ++ in_gains ++ " LIMIT 1");
        defer st.finalize();
        try st.bindAll(.{ tr.txn, gain_names[0], gain_names[1] });
        const before: i64 = if (try st.step()) blk: {
            const id = st.int(0);
            const old = st.int(1);
            if (amount == 0)
                try b.db.run("DELETE FROM posting WHERE id = ?", .{id})
            else
                try b.db.run("UPDATE posting SET amount = ? WHERE id = ?", .{ amount, id });
            break :blk old;
        } else blk: {
            if (amount != 0) try b.db.run("INSERT INTO posting (txn, account, amount) VALUES (?, ?, ?)", .{ tr.txn, try gainsAccount(b, security), amount });
            break :blk 0;
        };
        if (before != amount) try changed.append(b.a, tr.txn);
        try closeLots(b, tr.txn, taken.takes, quantity, net);
        try journal.assertBalanced(b.db, tr.txn);
    }
    return changed.items;
}

fn sum(b: Book, sql: []const u8, args: anytype) Error!i64 {
    var st = try b.db.prepare(sql);
    defer st.finalize();
    try st.bindAll(args);
    _ = try st.step();
    return st.int(0);
}

pub const Dividend = struct {
    date: []const u8,
    security: i64,
    /// Gross amount in EUR cents, before withholding.
    gross: i64,
    taxes: Taxes = .{},
    /// For dividends paid in another currency: its code and the gross amount in it.
    currency: []const u8 = "EUR",
    original: ?i64 = null,
};

/// Cash + net, withheld taxes as expenses, the gross as income tagged with the
/// security.
pub fn dividend(b: Book, broker: []const u8, d: Dividend) Error!i64 {
    try positive(d.gross);
    const acc = try b.broker(broker);
    var postings: std.ArrayList(journal.Posting) = .empty;
    try postings.append(b.a, .{ .account = acc.cash, .amount = d.gross - d.taxes.total() });
    try appendTaxes(b, &postings, d.taxes, 1);
    try postings.append(b.a, .{
        .account = try b.role(b.ledger.accounts.dividends),
        .amount = -d.gross,
        .security = d.security,
        .currency = d.currency,
        .original = if (d.original) |o| -o else null,
    });
    return journal.insert(b.db, .{ .id = b.id, .date = d.date, .description = "dividend", .postings = postings.items });
}

/// A booking as the parsers and the old single-entry rows describe it.
pub const Entry = struct {
    kind: Kind,
    date: []const u8,
    security: ?i64 = null,
    /// Millionths of a share, for trades.
    quantity: i64 = 0,
    /// Gross amount in `currency` cents (Kurswert, booking amount), positive.
    total: i64,
    /// EUR cents: trade fees, tax withheld on a dividend, otherwise a fee
    /// charged alongside.
    cost: i64 = 0,
    currency: []const u8 = "EUR",
    exchange_rate: f64 = 1.0,

    pub const Kind = enum { buy, sell, dividend, interest, deposit, withdrawal };

    /// A cost on a cash booking becomes a transaction of its own.
    pub fn separateFee(e: Entry) bool {
        return e.cost != 0 and switch (e.kind) {
            .interest, .deposit, .withdrawal => true,
            else => false,
        };
    }

    pub fn eur(e: Entry) i64 {
        return @intFromFloat(@round(@as(f64, @floatFromInt(e.total)) * e.exchange_rate));
    }
};

/// Books `e`; a separate fee takes `fee_id` (or the next free id).
pub fn entry(b: Book, broker: []const u8, e: Entry, fee_id: ?i64) Error!i64 {
    const total = e.eur();
    const trade: Trade = .{ .date = e.date, .security = e.security orelse 0, .quantity = e.quantity, .total = total, .fees = e.cost };
    const id = switch (e.kind) {
        .buy => return buy(b, broker, trade),
        .sell => return sell(b, broker, trade),
        .dividend => return dividend(b, broker, .{
            .date = e.date,
            .security = e.security orelse return error.UnknownSecurity,
            .gross = total,
            .taxes = .{ .kapest = e.cost },
            .currency = e.currency,
            .original = if (std.mem.eql(u8, e.currency, "EUR")) null else e.total,
        }),
        .interest => try interest(b, broker, e.date, total),
        .deposit => try deposit(b, broker, e.date, total),
        .withdrawal => try withdrawal(b, broker, e.date, total),
    };
    if (e.separateFee()) {
        var fb = b;
        fb.id = fee_id;
        _ = try fee(fb, broker, e.date, e.cost);
    }
    return id;
}

/// Shares held in a broker's depot, in millionths.
pub fn held(b: Book, broker: []const u8, security: i64) Error!i64 {
    const acc = try b.broker(broker);
    var total: i64 = 0;
    for (try openLots(b, acc.depot, security)) |l| total += l.quantity;
    return total;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

pub fn testBook(a: Allocator, ledger: Config.Ledger) !Book {
    const db = try sqlite.Db.open(":memory:");
    try @import("migrations.zig").run(db);
    try db.exec("PRAGMA foreign_keys = ON;");
    return .{ .db = db, .a = a, .ledger = ledger };
}

/// Sum of postings on `name`, in cents.
pub fn balance(b: Book, name: []const u8) !i64 {
    var st = try b.db.prepare(
        \\SELECT COALESCE(SUM(p.amount), 0) FROM posting p
        \\JOIN ledger_account a ON a.id = p.account WHERE a.name = ?
    );
    defer st.finalize();
    try st.bindAll(.{name});
    _ = try st.step();
    return st.int(0);
}

test "cash bookings land on the configured accounts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b = try testBook(arena.allocator(), .{ .owner = "Name", .brokers = &.{.{ .name = "Bank", .cash = "Assets:Name:Girokonto" }} });
    defer b.db.close();

    _ = try deposit(b, "Scalable", "2024-01-02", 100000);
    _ = try interest(b, "Scalable", "2024-01-31", 250);
    _ = try fee(b, "Scalable", "2024-01-31", 99);
    _ = try withdrawal(b, "Scalable", "2024-02-01", 10000);
    _ = try taxRefund(b, "Scalable", "2024-02-02", .{ .kapest = 1896, .soli = 104 });
    _ = try transfer(b, "Scalable", "Bank", "2024-02-03", 5000);

    try testing.expectEqual(@as(i64, 100000 + 250 - 99 - 10000 + 2000 - 5000), try balance(b, "Assets:Scalable:Cash"));
    try testing.expectEqual(@as(i64, 5000), try balance(b, "Assets:Name:Girokonto"));
    try testing.expectEqual(@as(i64, -90000), try balance(b, "Equity:Contributions"));
    try testing.expectEqual(@as(i64, -250), try balance(b, "Income:Interest"));
    try testing.expectEqual(@as(i64, 99), try balance(b, "Expenses:Fees"));
    try testing.expectEqual(@as(i64, -1896), try balance(b, "Expenses:Tax:KapESt"));
    try testing.expectEqual(@as(i64, -104), try balance(b, "Expenses:Tax:Soli"));
    // Unused tax accounts are not created.
    try testing.expect(try journal.accountByName(b.db, "Expenses:Tax:KiSt") == null);

    try testing.expectError(error.NotPositive, deposit(b, "Scalable", "2024-01-02", 0));
    try testing.expectError(error.NotPositive, taxRefund(b, "Scalable", "2024-01-02", .{}));
}

test "transfers between people are refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b = try testBook(arena.allocator(), .{ .owner = "Name", .brokers = &.{.{ .name = "Theirs", .owner = "Other" }} });
    defer b.db.close();
    try testing.expectError(error.MixedOwners, transfer(b, "Scalable", "Theirs", "2024-01-02", 100));
}

test "misconfigured role names fail instead of booking elsewhere" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b = try testBook(arena.allocator(), .{ .accounts = .{ .interest = "Zinsen" } });
    defer b.db.close();
    try testing.expectError(error.InvalidAccountName, interest(b, "Scalable", "2024-01-02", 100));
}

test "buy capitalises fees; sell closes lots FIFO and books the gain" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b = try testBook(arena.allocator(), .{ .owner = "Name" });
    defer b.db.close();
    try b.db.exec("INSERT INTO security (isin, name, type) VALUES ('US0378331005', 'Example Inc.', 'stock'), ('IE00B4L5Y983', 'World ETF', 'etf')");
    const acme = 1;
    const m = 1_000_000;

    _ = try deposit(b, "Scalable", "2024-01-01", 500000);
    _ = try buy(b, "Scalable", .{ .date = "2024-01-10", .security = acme, .quantity = 10 * m, .total = 100000, .fees = 100 });
    _ = try buy(b, "Scalable", .{ .date = "2024-02-10", .security = acme, .quantity = 10 * m, .total = 120000, .fees = 100 });
    try testing.expectEqual(@as(i64, 220200), try balance(b, "Assets:Scalable:Depot"));
    try testing.expect(try journal.accountByName(b.db, "Expenses:Fees") == null);

    // 15 shares: all of lot 1 (10 for 1001.00) and 5 of lot 2 (600.50) = 1601.50 cost.
    _ = try sell(b, "Scalable", .{ .date = "2024-03-10", .security = acme, .quantity = 15 * m, .total = 195000, .fees = 100, .taxes = .{ .kapest = 8222, .soli = 452 } });
    try testing.expectEqual(@as(i64, 220200 - 160150), try balance(b, "Assets:Scalable:Depot"));
    try testing.expectEqual(@as(i64, -(194900 - 160150)), try balance(b, "Income:Gains:Shares"));
    try testing.expectEqual(@as(i64, 8222), try balance(b, "Expenses:Tax:KapESt"));
    try testing.expectEqual(@as(i64, 500000 - 220200 + 194900 - 8674), try balance(b, "Assets:Scalable:Cash"));
    try testing.expectEqual(@as(i64, 5 * m), try held(b, "Scalable", acme));

    // The rest of lot 2 takes exactly its remaining cost, at a loss.
    _ = try sell(b, "Scalable", .{ .date = "2024-04-10", .security = acme, .quantity = 5 * m, .total = 50000 });
    try testing.expectEqual(@as(i64, 0), try balance(b, "Assets:Scalable:Depot"));
    try testing.expectEqual(@as(i64, -(194900 - 160150) + (60050 - 50000)), try balance(b, "Income:Gains:Shares"));
    try testing.expectEqual(@as(i64, 0), try held(b, "Scalable", acme));

    // Fees stay visible as their own postings: two buys and the first sell.
    var fees = try b.db.prepare("SELECT COUNT(*), SUM(amount) FROM posting WHERE fee");
    defer fees.finalize();
    _ = try fees.step();
    try testing.expectEqual(@as(i64, 3), fees.int(0));
    try testing.expectEqual(@as(i64, 300), fees.int(1));

    try testing.expectError(error.InsufficientHolding, sell(b, "Scalable", .{ .date = "2024-05-01", .security = acme, .quantity = 1, .total = 1 }));
    // The failed sell left nothing behind.
    var st = try b.db.prepare("SELECT COUNT(*) FROM txn WHERE date = '2024-05-01'");
    defer st.finalize();
    _ = try st.step();
    try testing.expectEqual(@as(i64, 0), st.int(0));
}

test "replay recomputes later sales after a corrected buy" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b = try testBook(arena.allocator(), .{ .owner = "Name" });
    defer b.db.close();
    try b.db.exec("INSERT INTO security (isin, name, type) VALUES ('US0378331005', 'Example Inc.', 'stock')");
    const m = 1_000_000;
    const first = try buy(b, "Scalable", .{ .date = "2024-01-10", .security = 1, .quantity = 10 * m, .total = 100000, .fees = 100 });
    _ = try buy(b, "Scalable", .{ .date = "2024-02-10", .security = 1, .quantity = 10 * m, .total = 120000 });
    const sale = try sell(b, "Scalable", .{ .date = "2024-03-10", .security = 1, .quantity = 15 * m, .total = 195000, .fees = 100, .taxes = .{ .kapest = 1000 } });
    const before = try balance(b, "Income:Gains:Shares");

    // The first buy was 110.00 a share, not 100.00.
    try b.db.run("UPDATE posting SET amount = amount + 10000 WHERE txn = ? AND quantity IS NOT NULL", .{first});
    try b.db.run("UPDATE posting SET amount = amount - 10000 WHERE txn = ? AND account = (SELECT id FROM ledger_account WHERE name = 'Assets:Scalable:Cash')", .{first});
    const depot = (try journal.accountByName(b.db, "Assets:Scalable:Depot")).?.id;
    const changed = try replay(b, depot, 1);
    try testing.expectEqualSlices(i64, &.{sale}, changed);
    try testing.expectEqual(before + 10000, try balance(b, "Income:Gains:Shares"));
    try testing.expectEqual(@as(i64, 5 * m), try held(b, "Scalable", 1));
    try testing.expectEqual(@as(i64, 60000), try balance(b, "Assets:Scalable:Depot"));

    // Nothing left to change on a second run.
    try testing.expectEqual(@as(usize, 0), (try replay(b, depot, 1)).len);
}

test "fractional ETF shares go to the other gains account" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b = try testBook(arena.allocator(), .{ .owner = "Name" });
    defer b.db.close();
    try b.db.exec("INSERT INTO security (isin, name, type) VALUES ('IE00B4L5Y983', 'World ETF', 'etf')");
    _ = try buy(b, "Scalable", .{ .date = "2024-01-10", .security = 1, .quantity = 3_333_333, .total = 33334 });
    _ = try sell(b, "Scalable", .{ .date = "2024-06-10", .security = 1, .quantity = 1_111_111, .total = 12000 });
    // Cost of a third of the lot, floored: 33334 × 1111111 / 3333333 = 11111.33… → 11111.
    try testing.expectEqual(@as(i64, -(12000 - 11111)), try balance(b, "Income:Gains:Other"));
    try testing.expectEqual(@as(i64, 33334 - 11111), try balance(b, "Assets:Scalable:Depot"));
}

test "dividends: net to cash, withholding as expense, gross as income" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b = try testBook(arena.allocator(), .{ .owner = "Name" });
    defer b.db.close();
    try b.db.exec("INSERT INTO security (isin, name) VALUES ('US0378331005', 'Example Inc.')");

    // $12.40 gross = €11.34; 15 % US withholding, German tax after crediting it.
    _ = try dividend(b, "Scalable", .{ .date = "2024-03-17", .security = 1, .gross = 1134, .taxes = .{ .quellensteuer = 170, .kapest = 114, .soli = 6 }, .currency = "USD", .original = 1240 });
    try testing.expectEqual(@as(i64, 1134 - 290), try balance(b, "Assets:Scalable:Cash"));
    try testing.expectEqual(@as(i64, -1134), try balance(b, "Income:Dividends"));
    try testing.expectEqual(@as(i64, 170), try balance(b, "Expenses:Tax:Quellensteuer"));

    var st = try b.db.prepare("SELECT security, quantity IS NULL, currency, original FROM posting p JOIN ledger_account a ON a.id = p.account WHERE a.name = 'Income:Dividends'");
    defer st.finalize();
    _ = try st.step();
    try testing.expectEqual(@as(i64, 1), st.int(0));
    try testing.expectEqual(@as(i64, 1), st.int(1));
    try testing.expectEqualStrings("USD", st.textRef(2).?);
    try testing.expectEqual(@as(i64, -1240), st.int(3));

    try testing.expectError(error.InvalidPosting, dividend(b, "Scalable", .{ .date = "2024-03-17", .security = 1, .gross = 100, .currency = "USD" }));
}
