//! The shortcuts (`dv add buy …`, parser results) as journal transactions,
//! booked to the accounts named in `config.zon`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("Config.zig");
const journal = @import("journal.zig");
const sqlite = @import("sqlite.zig");

pub const Error = error{NotPositive} || journal.Error || Allocator.Error;

pub const Broker = struct { cash: i64, depot: i64, owner: i64 };

pub const Book = struct {
    db: sqlite.Db,
    a: Allocator,
    ledger: Config.Ledger,

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
    return journal.insert(b.db, .{ .date = date, .description = "deposit", .postings = &.{
        .{ .account = acc.cash, .amount = cents },
        .{ .account = try b.role(b.ledger.accounts.contributions), .amount = -cents },
    } });
}

pub fn withdrawal(b: Book, broker: []const u8, date: []const u8, cents: i64) Error!i64 {
    try positive(cents);
    const acc = try b.broker(broker);
    return journal.insert(b.db, .{ .date = date, .description = "withdrawal", .postings = &.{
        .{ .account = acc.cash, .amount = -cents },
        .{ .account = try b.role(b.ledger.accounts.contributions), .amount = cents },
    } });
}

pub fn interest(b: Book, broker: []const u8, date: []const u8, cents: i64) Error!i64 {
    try positive(cents);
    const acc = try b.broker(broker);
    return journal.insert(b.db, .{ .date = date, .description = "interest", .postings = &.{
        .{ .account = acc.cash, .amount = cents },
        .{ .account = try b.role(b.ledger.accounts.interest), .amount = -cents },
    } });
}

/// A fee not tied to a trade, e.g. custody fees; trade fees are part of the
/// trade's cost or proceeds.
pub fn fee(b: Book, broker: []const u8, date: []const u8, cents: i64) Error!i64 {
    try positive(cents);
    const acc = try b.broker(broker);
    return journal.insert(b.db, .{ .date = date, .description = "fee", .postings = &.{
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
    return journal.insert(b.db, .{ .date = date, .description = "tax refund", .postings = postings.items });
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
    return journal.insert(b.db, .{ .date = date, .description = "transfer", .postings = &.{
        .{ .account = src.cash, .amount = -cents },
        .{ .account = dst.cash, .amount = cents },
    } });
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
