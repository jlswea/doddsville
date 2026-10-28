//! The journal as beancount text, so `bean-check` can verify balances and FIFO
//! lot costs independently of dv.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite.zig");
const journal = @import("journal.zig");

pub fn write(db: sqlite.Db, a: Allocator, roots: journal.Roots, w: *std.Io.Writer) !void {
    try w.writeAll("option \"operating_currency\" \"EUR\"\noption \"booking_method\" \"FIFO\"\n");
    inline for (.{ "assets", "liabilities", "equity", "income", "expenses" }) |r|
        try w.print("option \"name_{s}\" \"{s}\"\n", .{ r, @field(roots, r) });

    {
        var st = try db.prepare(
            \\SELECT s.id, s.isin, s.name, MIN(t.date) FROM security s
            \\JOIN posting p ON p.security = s.id AND p.quantity IS NOT NULL
            \\JOIN txn t ON t.id = p.txn
            \\GROUP BY s.id ORDER BY s.id
        );
        defer st.finalize();
        var first = true;
        while (try st.step()) : (first = false) {
            if (first) try w.writeByte('\n');
            try w.print("{s} commodity {s}\n", .{ st.textRef(3).?, try commodity(a, st.int(0), st.textRef(1)) });
            if (st.textRef(2)) |name| try w.print("  name: {f}\n", .{quoted(name)});
        }
    }

    {
        var st = try db.prepare(
            \\SELECT a.name, MIN(t.date), o.name FROM ledger_account a
            \\JOIN posting p ON p.account = a.id
            \\JOIN txn t ON t.id = p.txn
            \\LEFT JOIN person o ON o.id = a.owner
            \\GROUP BY a.id ORDER BY a.name
        );
        defer st.finalize();
        var first = true;
        while (try st.step()) : (first = false) {
            if (first) try w.writeByte('\n');
            try w.print("{s} open {s}\n", .{ st.textRef(1).?, st.textRef(0).? });
            if (st.textRef(2)) |owner| try w.print("  owner: {f}\n", .{quoted(owner)});
        }
    }

    var txns = try db.prepare("SELECT id, date, description FROM txn ORDER BY date, id");
    defer txns.finalize();
    while (try txns.step()) {
        try w.print("\n{s} * {f}\n  id: {d}\n", .{ txns.textRef(1).?, quoted(txns.textRef(2).?), txns.int(0) });
        var postings = try db.prepare(
            \\SELECT a.name, p.amount, p.quantity, p.security, s.isin FROM posting p
            \\JOIN ledger_account a ON a.id = p.account
            \\LEFT JOIN security s ON s.id = p.security
            \\WHERE p.txn = ? ORDER BY p.id
        );
        defer postings.finalize();
        try postings.bindAll(.{txns.int(0)});
        while (try postings.step()) {
            const account = postings.textRef(0).?;
            const amount = postings.int(1);
            const quantity = postings.optInt(2) orelse {
                try w.print("  {s}  {f} EUR\n", .{ account, decimal(amount, 2) });
                continue;
            };
            const name = try commodity(a, postings.int(3), postings.textRef(4));
            // A buy states the lot's total cost; a sell leaves the cost to
            // beancount's FIFO matching, which is the point of the check.
            if (quantity > 0)
                try w.print("  {s}  {f} {s} {{{{{f} EUR}}}}\n", .{ account, decimal(quantity, 6), name, decimal(amount, 2) })
            else
                try w.print("  {s}  {f} {s} {{}}\n", .{ account, decimal(quantity, 6), name });
        }
    }
}

fn commodity(a: Allocator, id: i64, isin: ?[]const u8) ![]const u8 {
    return isin orelse std.fmt.allocPrint(a, "SEC-{d}", .{id});
}

const Quoted = struct {
    s: []const u8,
    pub fn format(q: Quoted, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('"');
        for (q.s) |c| {
            if (c == '"' or c == '\\') try w.writeByte('\\');
            try w.writeByte(c);
        }
        try w.writeByte('"');
    }
};

fn quoted(s: []const u8) Quoted {
    return .{ .s = s };
}

/// A fixed-point integer with `places` decimals, trailing zeros after the
/// second decimal dropped.
const Decimal = struct {
    value: i64,
    places: u4,
    pub fn format(d: Decimal, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const scale = std.math.powi(u64, 10, d.places) catch unreachable;
        const abs: u64 = @abs(d.value);
        var frac = abs % scale;
        var digits: usize = d.places;
        while (digits > 2 and frac % 10 == 0) : (digits -= 1) frac /= 10;
        try w.print("{s}{d}", .{ if (d.value < 0) "-" else "", abs / scale });
        if (digits > 0) try w.print(".{d:0>[1]}", .{ frac, digits });
    }
};

fn decimal(value: i64, places: u4) Decimal {
    return .{ .value = value, .places = places };
}

const testing = std.testing;
const bookings = @import("bookings.zig");

test "journal as beancount" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const b = try bookings.testBook(arena.allocator(), .{ .owner = "Name" });
    defer b.db.close();
    try b.db.exec("INSERT INTO security (isin, name, type) VALUES ('US0378331005', 'Example \"Inc.\"', 'stock')");
    const m = 1_000_000;

    _ = try bookings.deposit(b, "Scalable", "2026-01-05", 200000);
    _ = try bookings.buy(b, "Scalable", .{ .date = "2026-02-02", .security = 1, .quantity = 10 * m, .total = 100000, .fees = 100 });
    _ = try bookings.sell(b, "Scalable", .{ .date = "2026-06-10", .security = 1, .quantity = 4_500_000, .total = 58500, .fees = 100, .taxes = .{ .kapest = 3337, .soli = 183 } });
    _ = try bookings.dividend(b, "Scalable", .{ .date = "2026-07-15", .security = 1, .gross = 5000, .taxes = .{ .quellensteuer = 750 }, .currency = "USD", .original = 5800 });

    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try write(b.db, arena.allocator(), .{}, &out.writer);
    try testing.expectEqualStrings(
        \\option "operating_currency" "EUR"
        \\option "booking_method" "FIFO"
        \\option "name_assets" "Assets"
        \\option "name_liabilities" "Liabilities"
        \\option "name_equity" "Equity"
        \\option "name_income" "Income"
        \\option "name_expenses" "Expenses"
        \\
        \\2026-02-02 commodity US0378331005
        \\  name: "Example \"Inc.\""
        \\
        \\2026-01-05 open Assets:Scalable:Cash
        \\  owner: "Name"
        \\2026-02-02 open Assets:Scalable:Depot
        \\  owner: "Name"
        \\2026-01-05 open Equity:Contributions
        \\2026-06-10 open Expenses:Tax:KapESt
        \\2026-07-15 open Expenses:Tax:Quellensteuer
        \\2026-06-10 open Expenses:Tax:Soli
        \\2026-07-15 open Income:Dividends
        \\2026-06-10 open Income:Gains:Shares
        \\
        \\2026-01-05 * "deposit"
        \\  id: 1
        \\  Assets:Scalable:Cash  2000.00 EUR
        \\  Equity:Contributions  -2000.00 EUR
        \\
        \\2026-02-02 * "buy"
        \\  id: 2
        \\  Assets:Scalable:Depot  10.00 US0378331005 {{1001.00 EUR}}
        \\  Assets:Scalable:Cash  -1001.00 EUR
        \\
        \\2026-06-10 * "sell"
        \\  id: 3
        \\  Assets:Scalable:Cash  548.80 EUR
        \\  Expenses:Tax:KapESt  33.37 EUR
        \\  Expenses:Tax:Soli  1.83 EUR
        \\  Assets:Scalable:Depot  -4.50 US0378331005 {}
        \\  Income:Gains:Shares  -133.55 EUR
        \\
        \\2026-07-15 * "dividend"
        \\  id: 4
        \\  Assets:Scalable:Cash  42.50 EUR
        \\  Expenses:Tax:Quellensteuer  7.50 EUR
        \\  Income:Dividends  -50.00 EUR
        \\
    , out.written());
}
