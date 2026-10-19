//! Port of commands/add_cmd.py. The seven near-identical Python branches are
//! folded into one table-driven flow; prompts and output are unchanged.

const std = @import("std");
const App = @import("../App.zig");
const f = @import("../format.zig");
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

    const total = if (args.kind.hasQuantity()) args.quantity * args.amount else args.amount;

    try app.print("\n{s}Recording {s} transaction:{s}\n", .{ f.BOLD, args.kind.upper(), f.RESET });
    try app.print("  Account:  {s}\n", .{account.name});
    if (security) |s| try app.print("  Security: {s}\n", .{s.name});
    if (args.kind.hasQuantity()) {
        try app.print("  Quantity: {d}\n", .{args.quantity});
        try app.print("  Price:    {s}\n", .{try f.cents(app.a, args.amount)});
        try app.print("  Total:    {s}\n", .{try f.cents(app.a, total)});
    } else {
        try app.print("  Amount:   {s}\n", .{try f.cents(app.a, args.amount)});
    }
    try app.print("  Cost:     {s}\n", .{try f.cents(app.a, args.cost)});
    try app.print("  Date:     {s}\n", .{args.date});
    try printDocs(app, resolved.ids);

    if (!confirmed(try app.input("\nCommit? (y/N) "))) return;

    const type_name = @tagName(args.kind);
    if (args.kind.hasQuantity()) {
        try app.db.run(
            \\INSERT INTO "transaction"
            \\   (account, security, type, quantity, unit_value, total_value, cost, date)
            \\   VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        , .{ account.id, security.?.id, type_name, args.quantity, args.amount, total, args.cost, args.date });
    } else if (security) |s| {
        try app.db.run(
            \\INSERT INTO "transaction"
            \\   (account, security, type, total_value, cost, date)
            \\   VALUES (?, ?, ?, ?, ?, ?)
        , .{ account.id, s.id, type_name, args.amount, args.cost, args.date });
    } else {
        try app.db.run(
            \\INSERT INTO "transaction"
            \\   (account, type, total_value, cost, date)
            \\   VALUES (?, ?, ?, ?, ?)
        , .{ account.id, type_name, args.amount, args.cost, args.date });
    }
    const txn_id = app.db.lastInsertRowId();
    try app.print("{s}Transaction recorded (ID: {d}).{s}\n", .{ f.GREEN, txn_id, f.RESET });

    try linkDocs(app, txn_id, resolved);
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
    try app.print("  From:     {s}\n", .{from.name});
    try app.print("  To:       {s}\n", .{to.name});
    try app.print("  Amount:   {s}\n", .{try f.cents(app.a, args.amount)});
    try app.print("  Cost:     {s}\n", .{try f.cents(app.a, args.cost)});
    try app.print("  Date:     {s}\n", .{args.date});
    try printDocs(app, resolved.ids);

    if (!confirmed(try app.input("\nCommit? (y/N) "))) return;

    try app.db.exec("BEGIN");
    errdefer app.db.exec("ROLLBACK") catch {};
    try app.db.run(
        \\INSERT INTO "transaction"
        \\   (account, type, total_value, cost, date)
        \\   VALUES (?, 'transfer', ?, ?, ?)
    , .{ from.id, -args.amount, args.cost, args.date });
    const outgoing = app.db.lastInsertRowId();
    try app.db.run(
        \\INSERT INTO "transaction"
        \\   (account, type, total_value, cost, date, linked_transaction)
        \\   VALUES (?, 'transfer', ?, 0, ?, ?)
    , .{ to.id, args.amount, args.date, outgoing });
    const incoming = app.db.lastInsertRowId();
    try app.db.run("UPDATE \"transaction\" SET linked_transaction = ? WHERE id = ?", .{ incoming, outgoing });
    try app.db.exec("COMMIT");

    try app.print("{s}Transfer recorded (IDs: {d} <-> {d}).{s}\n", .{ f.GREEN, outgoing, incoming, f.RESET });
    try linkDocs(app, outgoing, resolved);
}

fn pickAccount(app: *App, pattern: []const u8, label: []const u8, prompt: []const u8) !?lookup.Account {
    const results = try lookup.accountsLike(app, pattern);
    if (results.len == 0) {
        const cap = if (std.mem.eql(u8, label, "source")) "Source" else "Destination";
        try app.print("{s}{s} account '{s}' not found.{s}\n", .{ f.RED, cap, pattern, f.RESET });
        return null;
    }
    if (results.len == 1) return results[0];
    try app.print("Multiple {s} accounts match '{s}':\n", .{ label, pattern });
    for (results, 1..) |acc, i| try app.print("  {d}: {s}\n", .{ i, acc.name });
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
