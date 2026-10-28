//! Port of commands/add_cmd.py. The seven near-identical Python branches are
//! folded into one table-driven flow; prompts and output are unchanged.

const std = @import("std");
const App = @import("../App.zig");
const f = @import("../format.zig");
const bookings = @import("../bookings.zig");
const lookup = @import("../lookup.zig");
const paperless = @import("../paperless.zig");

pub const Kind = enum {
    buy,
    sell,
    dividend,
    interest,
    deposit,
    withdrawal,
    transfer,

    pub fn hasSecurity(k: Kind) bool {
        return k == .buy or k == .sell or k == .dividend;
    }

    pub fn hasQuantity(k: Kind) bool {
        return k == .buy or k == .sell;
    }

    fn upper(k: Kind) []const u8 {
        return switch (k) {
            .buy => "BUY",
            .sell => "SELL",
            .dividend => "DIVIDEND",
            .interest => "INTEREST",
            .deposit => "DEPOSIT",
            .withdrawal => "WITHDRAWAL",
            .transfer => "TRANSFER",
        };
    }
};

/// Already-validated arguments (validation happens in main, like argparse).
pub const Args = struct {
    kind: Kind,
    security: []const u8 = "",
    /// Millionths of a share.
    quantity: i64 = 0,
    /// price per share for buy/sell, amount otherwise
    amount: i64 = 0,
    cost: i64 = 0,
    /// ISO date, already resolved (defaults to today)
    date: []const u8,
    account: ?[]const u8 = null,
    from_account: []const u8 = "",
    to_account: []const u8 = "",
    docs: ?[]const []const u8 = null,
};

pub fn run(app: *App, args: Args) !void {
    if (args.kind == .transfer) return transfer(app, args);

    const account = (try lookup.getOrPromptAccount(app, args.account)) orelse return;
    var security: ?lookup.Security = null;
    if (args.kind.hasSecurity()) {
        security = (try lookup.getOrPromptSecurity(app, args.security)) orelse return;
    }

    var resolved: paperless.Resolved = .{ .ids = &.{}, .failed = &.{} };
    if (args.docs) |d| resolved = try paperless.resolveDocArgs(app, d);

    const total = if (args.kind.hasQuantity()) f.lineTotal(args.quantity, args.amount).? else args.amount;

    try app.print("\n{s}Recording {s} transaction:{s}\n", .{ f.BOLD, args.kind.upper(), f.RESET });
    try app.print("  Account:  {s}\n", .{account.name.slice()});
    if (security) |*s| try app.print("  Security: {s}\n", .{s.name.slice()});
    if (args.kind.hasQuantity()) {
        try app.print("  Quantity: {s}\n", .{try f.quantity(app.a, args.quantity)});
        try app.print("  Price:    {s}\n", .{try f.cents(app.a, args.amount)});
        try app.print("  Total:    {s}\n", .{try f.cents(app.a, total)});
    } else {
        try app.print("  Amount:   {s}\n", .{try f.cents(app.a, args.amount)});
    }
    try app.print("  Cost:     {s}\n", .{try f.cents(app.a, args.cost)});
    try app.print("  Date:     {s}\n", .{args.date});
    try printDocs(app, resolved.ids);

    if (!confirmed(try app.input("\nCommit? (y/N) "))) return;

    const b = book(app);
    const name = account.name.slice();
    const sec = if (security) |x| x.id else 0;
    const txn_id = bookOne(b, args, name, sec, total) catch |err| switch (err) {
        error.InsufficientHolding => {
            try app.print("{s}Not enough shares held to sell {s}.{s}\n", .{ f.RED, try f.quantity(app.a, args.quantity), f.RESET });
            return;
        },
        error.NotPositive => {
            try app.print("{s}Amounts must be positive.{s}\n", .{ f.RED, f.RESET });
            return;
        },
        else => return err,
    };
    try app.print("{s}Transaction recorded (ID: {d}).{s}\n", .{ f.GREEN, txn_id, f.RESET });

    try linkDocs(app, txn_id, resolved);
}

fn book(app: *App) bookings.Book {
    return .{ .db = app.db, .a = app.a, .ledger = app.config.ledger };
}

/// The transaction for one `dv add`. A cost on a cash booking is a fee
/// charged alongside and gets its own transaction.
fn bookOne(b: bookings.Book, args: Args, broker: []const u8, security: i64, total: i64) !i64 {
    const trade: bookings.Trade = .{ .date = args.date, .security = security, .quantity = args.quantity, .total = total, .fees = args.cost };
    const id = switch (args.kind) {
        .buy => return bookings.buy(b, broker, trade),
        .sell => return bookings.sell(b, broker, trade),
        .dividend => return bookings.dividend(b, broker, .{ .date = args.date, .security = security, .gross = args.amount, .taxes = .{ .kapest = args.cost } }),
        .interest => try bookings.interest(b, broker, args.date, args.amount),
        .deposit => try bookings.deposit(b, broker, args.date, args.amount),
        .withdrawal => try bookings.withdrawal(b, broker, args.date, args.amount),
        .transfer => unreachable,
    };
    if (args.cost > 0) _ = try bookings.fee(b, broker, args.date, args.cost);
    return id;
}

fn transfer(app: *App, args: Args) !void {
    const from = (try pickAccount(app, args.from_account, "source", "Select source: ")) orelse return;
    const to = (try pickAccount(app, args.to_account, "destination", "Select destination: ")) orelse return;
    if (from.id == to.id) {
        try app.print("{s}Source and destination accounts must be different.{s}\n", .{ f.RED, f.RESET });
        return;
    }

    var resolved: paperless.Resolved = .{ .ids = &.{}, .failed = &.{} };
    if (args.docs) |d| resolved = try paperless.resolveDocArgs(app, d);

    try app.print("\n{s}Recording TRANSFER transaction:{s}\n", .{ f.BOLD, f.RESET });
    try app.print("  From:     {s}\n", .{from.name.slice()});
    try app.print("  To:       {s}\n", .{to.name.slice()});
    try app.print("  Amount:   {s}\n", .{try f.cents(app.a, args.amount)});
    try app.print("  Cost:     {s}\n", .{try f.cents(app.a, args.cost)});
    try app.print("  Date:     {s}\n", .{args.date});
    try printDocs(app, resolved.ids);

    if (!confirmed(try app.input("\nCommit? (y/N) "))) return;

    const b = book(app);
    const id = try bookings.transfer(b, from.name.slice(), to.name.slice(), args.date, args.amount);
    if (args.cost > 0) _ = try bookings.fee(b, from.name.slice(), args.date, args.cost);
    try app.print("{s}Transfer recorded (ID: {d}).{s}\n", .{ f.GREEN, id, f.RESET });
    try linkDocs(app, id, resolved);
}

fn pickAccount(app: *App, pattern: []const u8, label: []const u8, prompt: []const u8) !?lookup.Account {
    var buf: [lookup.max_matches + 1]lookup.Account = undefined;
    const results = try lookup.accountsLike(app, pattern, &buf);
    if (results.len == 0) {
        const cap = if (std.mem.eql(u8, label, "source")) "Source" else "Destination";
        try app.print("{s}{s} account '{s}' not found.{s}\n", .{ f.RED, cap, pattern, f.RESET });
        return null;
    }
    if (results.len > lookup.max_matches) {
        try app.print("{s}More than {d} {s} accounts match '{s}'; be more specific.{s}\n", .{ f.RED, lookup.max_matches, label, pattern, f.RESET });
        return null;
    }
    if (results.len == 1) return results[0];
    try app.print("Multiple {s} accounts match '{s}':\n", .{ label, pattern });
    for (results, 1..) |*acc, i| try app.print("  {d}: {s}\n", .{ i, acc.name.slice() });
    return lookup.pick(app, lookup.Account, results, prompt);
}

fn confirmed(answer: []const u8) bool {
    return std.ascii.eqlIgnoreCase(answer, "y");
}

fn printDocs(app: *App, ids: []const i64) !void {
    if (ids.len == 0) return;
    try app.out.writeAll("  Docs:     ");
    for (ids, 0..) |d, i| {
        if (i > 0) try app.out.writeAll(", ");
        try app.print("{d}", .{d});
    }
    try app.out.writeAll("\n");
}

fn linkDocs(app: *App, txn_id: i64, resolved: paperless.Resolved) !void {
    if (resolved.ids.len > 0) {
        try paperless.insertTransactionDocuments(app, txn_id, resolved.ids);
        try app.print("Linked {d} document(s) to transaction {d}\n", .{ resolved.ids.len, txn_id });
        try paperless.backlink(app, resolved.ids, &.{txn_id});
    }
    if (resolved.failed.len > 0) {
        try app.print("\n{s}Warning: {d} document(s) could not be linked:{s}\n", .{ f.YELLOW, resolved.failed.len, f.RESET });
        for (resolved.failed) |x| try app.print("  - {s}\n", .{x});
        try app.line("\nTo attach manually later, use:");
        try app.print("  dv doc add {d} <paperless_doc_id>\n", .{txn_id});
    }
}
