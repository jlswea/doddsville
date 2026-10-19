//! Port of commands/list_cmd.py.

const std = @import("std");
const App = @import("../App.zig");
const f = @import("../format.zig");

const Row = struct {
    id: i64,
    account: []const u8,
    type: []const u8,
    security: ?[]const u8,
    qty: ?i64,
    unit: ?i64,
    total: ?i64,
    cost: ?i64,
    date: []const u8,
    doc_ids: ?[]const u8,
    currency: []const u8,
    exchange_rate: f64,
};

// Binding NULL disables a filter.
const rows_sql =
    \\SELECT t.id, a.name, t.type, s.name, t.quantity, t.unit_value, t.total_value,
    \\       t.cost, t.date,
    \\       (SELECT GROUP_CONCAT(paperless_id) FROM transaction_document WHERE transaction_id = t.id),
    \\       t.currency, t.exchange_rate
    \\FROM "transaction" t
    \\JOIN account a ON t.account = a.id
    \\LEFT JOIN security s ON t.security = s.id
    \\WHERE (?1 IS NULL OR a.name LIKE ?1) AND (?2 IS NULL OR t.type = ?2)
    \\ORDER BY t.date DESC, t.id DESC
;

pub fn run(app: *App, account: ?[]const u8, txn_type: ?[]const u8) !void {
    const a = app.a;
    const pattern: ?[]const u8 = if (account) |acc| try app.fmt("%{s}%", .{acc}) else null;

    var st = try app.db.prepare(rows_sql);
    defer st.finalize();
    try st.bindAll(.{ pattern, txn_type });

    var rows: std.ArrayList(Row) = .empty;
    while (try st.step()) try rows.append(a, .{
        .id = st.int(0),
        .account = (try st.text(a, 1)) orelse "",
        .type = (try st.text(a, 2)) orelse "",
        .security = try st.text(a, 3),
        .qty = st.optInt(4),
        .unit = st.optInt(5),
        .total = st.optInt(6),
        .cost = st.optInt(7),
        .date = (try st.text(a, 8)) orelse "",
        .doc_ids = try st.text(a, 9),
        .currency = (try st.text(a, 10)) orelse "EUR",
        .exchange_rate = blk: {
            const r = st.optFloat(11) orelse 1.0;
            break :blk if (r == 0) 1.0 else r; // Python: `exchange_rate or 1.0`
        },
    });

    if (rows.items.len == 0) {
        try app.line("No transactions found.");
        return;
    }

    const paperless_url = std.mem.trimEnd(u8, app.config.get("paperless_url") orelse "", "/");
    var has_fx = false;
    for (rows.items) |r| if (r.currency.len > 0 and !std.mem.eql(u8, r.currency, "EUR")) {
        has_fx = true;
    };

    try app.print("{s}{s} {s} {s} {s} {s} {s} {s} {s} ", .{
        f.BOLD,
        try f.left(a, "ID", 5),
        try f.left(a, "Date", 12),
        try f.left(a, "Account", 15),
        try f.left(a, "Type", 10),
        try f.left(a, "Security", 20),
        try f.left(a, "Qty", 6),
        try f.left(a, "Unit", 10),
        try f.left(a, "Total", 12),
    });
    if (has_fx) try app.print("{s} {s} ", .{ try f.left(a, "Ccy", 4), try f.left(a, "EUR", 10) });
    try app.print("{s} Docs{s}\n", .{ try f.left(a, "Cost", 8), f.RESET });
    try app.line(if (has_fx) f.rep("-", 130) else f.rep("-", 115));

    for (rows.items) |r| {
        // str(security).split(" ")[0] or "-"
        const sec_first = if (r.security) |s| s[0 .. std.mem.indexOfScalar(u8, s, ' ') orelse s.len] else "";
        const security = if (sec_first.len > 0) sec_first else "-";
        const qty = if (r.qty) |q| (if (q != 0) try f.int(a, q) else "-") else "-";
        const unit = try centsOrDash(a, r.unit);
        const total = try centsOrDash(a, r.total);
        const cost = try centsOrDash(a, r.cost);

        var docs: []const u8 = "-";
        if (r.doc_ids) |ids| if (ids.len > 0) {
            if (paperless_url.len > 0) {
                var buf: std.ArrayList(u8) = .empty;
                var it = std.mem.splitScalar(u8, ids, ',');
                var first = true;
                while (it.next()) |d| {
                    if (!first) try buf.appendSlice(a, ", ");
                    first = false;
                    try buf.print(a, "{s}/documents/{s}", .{ paperless_url, d });
                }
                docs = buf.items;
            } else docs = ids;
        };

        try app.print("{s} {s} {s} {s} {s} {s} {s} {s} ", .{
            try f.left(a, try f.int(a, r.id), 5),
            try f.left(a, r.date, 12),
            try f.left(a, r.account, 15),
            try f.left(a, r.type, 10),
            try f.left(a, security, 20),
            try f.left(a, qty, 6),
            try f.left(a, unit, 10),
            try f.left(a, total, 12),
        });
        if (has_fx) {
            var eur: []const u8 = "-";
            if (r.total) |t| if (t != 0) {
                const v: f64 = @as(f64, @floatFromInt(t)) * r.exchange_rate;
                eur = try f.cents(a, @intFromFloat(@trunc(v)));
            };
            try app.print("{s} {s} ", .{ try f.left(a, r.currency, 4), try f.left(a, eur, 10) });
        }
        try app.print("{s} {s}\n", .{ try f.left(a, cost, 8), docs });
    }
}

fn centsOrDash(a: std.mem.Allocator, v: ?i64) ![]const u8 {
    const x = v orelse return "-";
    return if (x != 0) f.cents(a, x) else "-";
}
