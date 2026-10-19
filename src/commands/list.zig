//! Port of commands/list_cmd.py.

const std = @import("std");
const App = @import("../App.zig");
const f = @import("../format.zig");

// Binding NULL disables a filter.
const where =
    \\FROM "transaction" t
    \\JOIN account a ON t.account = a.id
    \\LEFT JOIN security s ON t.security = s.id
    \\WHERE (?1 IS NULL OR a.name LIKE ?1) AND (?2 IS NULL OR t.type = ?2)
;

const rows_sql =
    \\SELECT t.id, a.name, t.type, s.name, t.quantity, t.unit_value, t.total_value,
    \\       t.cost, t.date,
    \\       (SELECT GROUP_CONCAT(paperless_id) FROM transaction_document WHERE transaction_id = t.id),
    \\       t.currency, t.exchange_rate
++ "\n" ++ where ++ "\n" ++
    \\ORDER BY t.date DESC, t.id DESC
;

// The header depends on whether any listed row is non-EUR, so it has to be known before the first row.
const has_fx_sql = "SELECT EXISTS(SELECT 1 " ++ where ++
    " AND t.currency IS NOT NULL AND t.currency <> '' AND t.currency <> 'EUR')";

const row_scratch_size = 16 * 1024;

pub fn run(app: *App, account: ?[]const u8, txn_type: ?[]const u8) !void {
    var pattern_buf: [256]u8 = undefined;
    const pattern: ?[]const u8 = if (account) |acc|
        std.fmt.bufPrint(&pattern_buf, "%{s}%", .{acc}) catch return error.AccountFilterTooLong
    else
        null;

    const has_fx = blk: {
        var st = try app.db.prepare(has_fx_sql);
        defer st.finalize();
        try st.bindAll(.{ pattern, txn_type });
        _ = try st.step();
        break :blk st.int(0) != 0;
    };

    var st = try app.db.prepare(rows_sql);
    defer st.finalize();
    try st.bindAll(.{ pattern, txn_type });

    const paperless_url = std.mem.trimEnd(u8, app.config.get("paperless_url") orelse "", "/");
    var scratch_buf: [row_scratch_size]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&scratch_buf);

    var any = false;
    while (try st.step()) {
        scratch.reset();
        const a = scratch.allocator();
        if (!any) try header(app, a, has_fx);
        any = true;

        // Text is borrowed from SQLite and only valid until the next step.
        const id = st.int(0);
        const account_name = st.textRef(1) orelse "";
        const ttype = st.textRef(2) orelse "";
        const security_full = st.textRef(3);
        const qty = st.optInt(4);
        const unit = st.optInt(5);
        const total = st.optInt(6);
        const cost = st.optInt(7);
        const date = st.textRef(8) orelse "";
        const doc_ids = st.textRef(9);
        const currency = st.textRef(10) orelse "EUR";
        const rate = blk: {
            const r = st.optFloat(11) orelse 1.0;
            break :blk if (r == 0) 1.0 else r; // Python: `exchange_rate or 1.0`
        };

        // str(security).split(" ")[0] or "-"
        const sec_first = if (security_full) |s| s[0 .. std.mem.indexOfScalar(u8, s, ' ') orelse s.len] else "";
        const security = if (sec_first.len > 0) sec_first else "-";
        const qty_str = if (qty) |q| (if (q != 0) try f.int(a, q) else "-") else "-";

        var docs: []const u8 = "-";
        if (doc_ids) |ids| if (ids.len > 0) {
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
            try f.left(a, try f.int(a, id), 5),
            try f.left(a, date, 12),
            try f.left(a, account_name, 15),
            try f.left(a, ttype, 10),
            try f.left(a, security, 20),
            try f.left(a, qty_str, 6),
            try f.left(a, try centsOrDash(a, unit), 10),
            try f.left(a, try centsOrDash(a, total), 12),
        });
        if (has_fx) {
            var eur: []const u8 = "-";
            if (total) |t| if (t != 0) {
                const v: f64 = @as(f64, @floatFromInt(t)) * rate;
                eur = try f.cents(a, @intFromFloat(@trunc(v)));
            };
            try app.print("{s} {s} ", .{ try f.left(a, if (currency.len > 0) currency else "EUR", 4), try f.left(a, eur, 10) });
        }
        try app.print("{s} {s}\n", .{ try f.left(a, try centsOrDash(a, cost), 8), docs });
    }

    if (!any) try app.line("No transactions found.");
}

fn header(app: *App, a: std.mem.Allocator, has_fx: bool) !void {
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
}

fn centsOrDash(a: std.mem.Allocator, v: ?i64) ![]const u8 {
    const x = v orelse return "-";
    return if (x != 0) f.cents(a, x) else "-";
}
