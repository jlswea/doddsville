//! `dv edit`: correct or delete a journal transaction. A corrected trade
//! changes the FIFO cost of later sales of that security, so their gains are
//! recomputed and listed.

const std = @import("std");
const App = @import("../App.zig");
const bookings = @import("../bookings.zig");
const f = @import("../format.zig");
const ledger_cmd = @import("ledger.zig");
const lookup = @import("../lookup.zig");
const ui = @import("../ui.zig");

/// A transaction as the edit form shows it.
const Loaded = struct {
    kind: ?bookings.Entry.Kind,
    broker: ?[]const u8,
    security: ?i64,
    form: ui.EditTxn,
    /// Gross amount in `form.currency` cents, kept when quantity and price stay.
    total: i64,
    taxes: bookings.Taxes,
};

pub fn run(app: *App, txn_id: i64) !void {
    try ledger_cmd.sync(app);
    const b: bookings.Book = .{ .db = app.db, .a = app.a, .ledger = app.config.ledger };
    const t = (try load(b, txn_id)) orelse {
        try app.print("{s}Transaction {d} not found.{s}\n", .{ f.RED, txn_id, f.RESET });
        return;
    };

    if (t.kind == null or t.broker == null) {
        try app.print("Transaction {d} ({s}) can only be deleted here.\n", .{ txn_id, t.form.type });
        if (!std.ascii.eqlIgnoreCase(f.strip(try app.input("Delete it? (y/N) ")), "y")) return;
        return save(app, b, txn_id, null);
    }

    try app.print("Editing transaction {d} (account: {s})\n", .{ txn_id, t.broker.? });
    const result = (try ui.editTransaction(app, t.form)) orelse return save(app, b, txn_id, null);

    const kind = std.meta.stringToEnum(bookings.Entry.Kind, result.type) orelse t.kind.?;
    var security = t.security;
    const stock = kind == .buy or kind == .sell or kind == .dividend;
    if (stock and !std.mem.eql(u8, result.security, t.form.security)) {
        if (try lookup.getOrPromptSecurity(app, result.security)) |sec| {
            security = sec.id;
        } else {
            try app.print("{s}Security not found, keeping previous.{s}\n", .{ f.YELLOW, f.RESET });
        }
    }
    if (stock and security == null) {
        try app.print("{s}A {s} needs a security.{s}\n", .{ f.RED, result.type, f.RESET });
        return;
    }

    const quantity = if (result.quantity == 0) f.quantity_scale else result.quantity;
    const total = if (quantity == t.form.quantity and result.unit_price_cents == t.form.unit_price_cents)
        t.total
    else
        f.lineTotal(quantity, result.unit_price_cents).?;
    try save(app, b, txn_id, .{
        .broker = t.broker.?,
        .entry = .{
            .kind = kind,
            .date = result.date,
            .security = if (stock) security else null,
            .quantity = if (kind == .buy or kind == .sell) quantity else 0,
            .total = total,
            .cost = result.cost_cents,
            .currency = result.currency,
            .exchange_rate = result.exchange_rate,
        },
        // An unchanged withholding keeps its split into the individual taxes.
        .taxes = if (kind == .dividend and result.cost_cents == t.form.cost_cents) t.taxes else null,
    });
}

const Pair = struct { depot: i64, security: i64 };

/// Books the replacement without touching lots, then replays every security
/// involved so FIFO follows the dates.
fn rebook(app: *App, b: bookings.Book, id: i64, replacement: ?Replacement, pairs: *std.ArrayList(Pair), changed: *std.ArrayList(i64)) !void {
    if (replacement) |r| try bookReplacement(app, b, id, r, pairs);
    for (pairs.items) |p| for (try bookings.replay(b, p.depot, p.security)) |sale| {
        if (sale != id and std.mem.indexOfScalar(i64, changed.items, sale) == null) try changed.append(app.a, sale);
    };
}

fn bookReplacement(app: *App, b: bookings.Book, id: i64, r: Replacement, pairs: *std.ArrayList(Pair)) !void {
    var rb = b;
    rb.id = id;
    rb.defer_lots = true;
    if (r.taxes) |taxes| {
        _ = try bookings.dividend(rb, r.broker, .{
            .date = r.entry.date,
            .security = r.entry.security.?,
            .gross = r.entry.eur(),
            .taxes = taxes,
            .currency = r.entry.currency,
            .original = if (std.mem.eql(u8, r.entry.currency, "EUR")) null else r.entry.total,
        });
    } else _ = try bookings.entry(rb, r.broker, r.entry, null);
    if (r.entry.security) |sec| if (r.entry.kind == .buy or r.entry.kind == .sell)
        try pairs.append(app.a, .{ .depot = (try b.broker(r.broker)).depot, .security = sec });
}

const Replacement = struct {
    broker: []const u8,
    entry: bookings.Entry,
    taxes: ?bookings.Taxes,
};

/// Deletes the transaction, books the replacement under the same id (which
/// paperless documents refer to) and replays the lots of every security
/// involved, all or nothing.
fn save(app: *App, b: bookings.Book, id: i64, replacement: ?Replacement) !void {
    try app.db.exec("BEGIN");
    var done = false;
    defer if (!done) app.db.exec("ROLLBACK") catch {};

    var docs: std.ArrayList(i64) = .empty;
    {
        var st = try app.db.prepare("SELECT paperless_id FROM txn_document WHERE txn = ?");
        defer st.finalize();
        try st.bindAll(.{id});
        while (try st.step()) try docs.append(app.a, st.int(0));
    }
    var pairs: std.ArrayList(Pair) = .empty;
    {
        var st = try app.db.prepare("SELECT DISTINCT account, security FROM posting WHERE txn = ? AND quantity IS NOT NULL");
        defer st.finalize();
        try st.bindAll(.{id});
        while (try st.step()) try pairs.append(app.a, .{ .depot = st.int(0), .security = st.int(1) });
    }
    for (pairs.items) |p| {
        try app.db.run("DELETE FROM lot_close WHERE lot IN (SELECT id FROM lot WHERE account = ? AND security = ?)", .{ p.depot, p.security });
        try app.db.run("DELETE FROM lot WHERE account = ? AND security = ?", .{ p.depot, p.security });
    }
    try app.db.run("DELETE FROM txn WHERE id = ?", .{id});

    var changed: std.ArrayList(i64) = .empty;
    rebook(app, b, id, replacement, &pairs, &changed) catch |err| switch (err) {
        error.InsufficientHolding => {
            try app.print("{s}A sale would sell more shares than held at its date; nothing was changed.{s}\n", .{ f.RED, f.RESET });
            return;
        },
        error.NotPositive => {
            try app.print("{s}Amounts must be positive; nothing was changed.{s}\n", .{ f.RED, f.RESET });
            return;
        },
        else => return err,
    };
    if (replacement != null)
        for (docs.items) |d| try app.db.run("INSERT INTO txn_document (txn, paperless_id) VALUES (?, ?)", .{ id, d });
    try app.db.exec("COMMIT");
    done = true;

    if (replacement == null) {
        try app.print("{s}Transaction {d} deleted.{s}\n", .{ f.GREEN, id, f.RESET });
    } else {
        try app.print("{s}Transaction {d} updated.{s}\n", .{ f.GREEN, id, f.RESET });
    }
    if (changed.items.len > 0) {
        try app.print("{s}Recomputed the gain of later sale(s): ", .{f.YELLOW});
        for (changed.items, 0..) |s, i| try app.print("{s}{d}", .{ if (i > 0) ", " else "", s });
        try app.print("{s}\n", .{f.RESET});
    }
}

fn load(b: bookings.Book, id: i64) !?Loaded {
    const a = b.a;
    var st = try b.db.prepare("SELECT date, description FROM txn WHERE id = ?");
    defer st.finalize();
    try st.bindAll(.{id});
    if (!try st.step()) return null;
    const date = (try st.text(a, 0)).?;
    const description = (try st.text(a, 1)).?;

    var ps = try b.db.prepare(
        \\SELECT a.name, a.kind, p.amount, p.quantity, p.security, p.fee, p.currency, p.original
        \\FROM posting p JOIN ledger_account a ON a.id = p.account WHERE p.txn = ? ORDER BY p.id
    );
    defer ps.finalize();
    try ps.bindAll(.{id});
    const names = b.ledger.accounts;
    var broker: ?[]const u8 = null;
    var security: ?i64 = null;
    var quantity: i64 = 0;
    var gross: i64 = 0;
    var fees: i64 = 0;
    var taxes: bookings.Taxes = .{};
    var currency: []const u8 = "EUR";
    var original: ?i64 = null;
    while (try ps.step()) {
        const name = ps.textRef(0).?;
        const kind = ps.textRef(1).?;
        const amount = ps.int(2);
        const fee = ps.int(5) != 0;
        if (broker == null) if (b.ledger.brokerOf(name)) |br| {
            broker = try a.dupe(u8, br);
        };
        if (ps.optInt(4)) |sec| security = sec;
        if (ps.optInt(3)) |q| quantity = @intCast(@abs(q));
        if (fee) fees += amount else if (ps.optInt(3) != null or std.mem.eql(u8, kind, "income")) gross += amount;
        if (std.mem.eql(u8, name, names.kapest)) taxes.kapest += amount;
        if (std.mem.eql(u8, name, names.soli)) taxes.soli += amount;
        if (std.mem.eql(u8, name, names.kist)) taxes.kist += amount;
        if (std.mem.eql(u8, name, names.quellensteuer)) taxes.quellensteuer += amount;
        if (ps.optInt(7)) |o| {
            currency = try a.dupe(u8, ps.textRef(6).?);
            original = @intCast(@abs(o));
        }
    }
    gross = @intCast(@abs(gross));

    const kind = std.meta.stringToEnum(bookings.Entry.Kind, description);
    const trade = kind == .buy or kind == .sell;
    // A cash booking's amount is its contribution or withdrawal: the size of
    // the transaction.
    if (gross == 0) gross = try sum(b, "SELECT COALESCE(SUM(amount), 0) FROM posting WHERE txn = ? AND amount > 0 AND NOT fee", id);
    const total = original orelse gross;
    const rate: f64 = if (original) |o| @as(f64, @floatFromInt(gross)) / @as(f64, @floatFromInt(o)) else 1.0;
    const qty = if (trade) quantity else f.quantity_scale;
    var sec_name: []const u8 = "";
    if (security) |sid| {
        var ss = try b.db.prepare("SELECT COALESCE(NULLIF(TRIM(name), ''), isin, '') FROM security WHERE id = ?");
        defer ss.finalize();
        try ss.bindAll(.{sid});
        if (try ss.step()) sec_name = (try ss.text(a, 0)).?;
    }
    return .{
        .kind = kind,
        .broker = broker,
        .security = security,
        .total = total,
        .taxes = taxes,
        .form = .{
            .type = description,
            .date = date,
            .security = sec_name,
            .quantity = qty,
            .unit_price_cents = if (trade and qty > 0) @intCast(@divTrunc(@as(i128, total) * f.quantity_scale + @divTrunc(qty, 2), qty)) else total,
            .cost_cents = if (kind == .dividend) taxes.total() else fees,
            .currency = currency,
            .exchange_rate = rate,
        },
    };
}

fn sum(b: bookings.Book, sql: []const u8, id: i64) !i64 {
    var st = try b.db.prepare(sql);
    defer st.finalize();
    try st.bindAll(.{id});
    _ = try st.step();
    return st.int(0);
}
