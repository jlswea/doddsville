//! Port of commands/edit_cmd.py.

const std = @import("std");
const App = @import("../App.zig");
const f = @import("../format.zig");
const lookup = @import("../lookup.zig");
const ui = @import("../ui.zig");

pub fn run(app: *App, txn_id: i64) !void {
    var st = try app.db.prepare(
        \\SELECT t.type, t.total_value, t.unit_value, t.quantity, t.cost, t.date,
        \\       t.linked_transaction, t.currency, t.exchange_rate,
        \\       s.name AS security_name, s.id AS security_id, a.name AS account_name
        \\FROM "transaction" t
        \\LEFT JOIN security s ON t.security = s.id
        \\LEFT JOIN account a ON t.account = a.id
        \\WHERE t.id = ?
    );
    defer st.finalize();
    try st.bindAll(.{txn_id});
    if (!try st.step()) {
        try app.print("{s}Transaction {d} not found.{s}\n", .{ f.RED, txn_id, f.RESET });
        return;
    }
    const a = app.a;
    const date = (try st.text(a, 5)) orelse "";
    const linked = st.optInt(6);
    const security_name = try st.text(a, 9);
    const security_id = st.optInt(10);
    const account_name = (try st.text(a, 11)) orelse "None";

    // `x or default` semantics from the Python version
    const nz = struct {
        fn int(v: ?i64, d: i64) i64 {
            const x = v orelse return d;
            return if (x == 0) d else x;
        }
    };
    const rate = st.optFloat(8) orelse 1.0;
    const currency = (try st.text(a, 7)) orelse "EUR";
    const txn: ui.EditTxn = .{
        .type = (try st.text(a, 0)) orelse "",
        .date = date,
        .security = security_name orelse "",
        .quantity = nz.int(st.optInt(3), 1),
        .unit_price_cents = nz.int(st.optInt(2), 0),
        .cost_cents = nz.int(st.optInt(4), 0),
        .currency = if (currency.len > 0) currency else "EUR",
        .exchange_rate = if (rate == 0) 1.0 else rate,
    };

    try app.print("Editing transaction {d} (account: {s})\n", .{ txn_id, account_name });
    const result = (try ui.editTransaction(app, txn)) orelse {
        if (linked) |l| {
            try app.db.run("DELETE FROM \"transaction\" WHERE id = ?", .{l});
            try app.print("  Deleted linked transfer leg (ID {d})\n", .{l});
        }
        try app.db.run("DELETE FROM \"transaction\" WHERE id = ?", .{txn_id});
        try app.print("{s}Transaction {d} deleted.{s}\n", .{ f.GREEN, txn_id, f.RESET });
        return;
    };

    var new_security_id: ?i64 = security_id;
    const stock = std.mem.eql(u8, result.type, "buy") or std.mem.eql(u8, result.type, "sell") or std.mem.eql(u8, result.type, "dividend");
    if (stock) {
        const name = result.security;
        if (name.len > 0 and !std.mem.eql(u8, name, security_name orelse "")) {
            if (try lookup.getOrPromptSecurity(app, name)) |sec| {
                new_security_id = sec.id;
            } else {
                try app.print("{s}Security not found, keeping previous.{s}\n", .{ f.YELLOW, f.RESET });
            }
        }
    } else new_security_id = null;

    const new_unit = result.unit_price_cents;
    const new_qty = if (result.quantity == 0) 1 else result.quantity;
    const new_total = new_unit * new_qty;

    try app.db.exec("BEGIN");
    errdefer app.db.exec("ROLLBACK") catch {};
    try app.db.run(
        \\UPDATE "transaction"
        \\SET type = ?, security = ?, total_value = ?, unit_value = ?,
        \\    quantity = ?, cost = ?, date = ?, currency = ?, exchange_rate = ?
        \\WHERE id = ?
    , .{ result.type, new_security_id, new_total, new_unit, new_qty, result.cost_cents, result.date, result.currency, result.exchange_rate, txn_id });
    if (linked) |l| try app.db.run(
        \\UPDATE "transaction" SET total_value = ?, date = ? WHERE id = ?
    , .{ -new_total, result.date, l });
    try app.db.exec("COMMIT");
    try app.print("{s}Transaction {d} updated.{s}\n", .{ f.GREEN, txn_id, f.RESET });
}
