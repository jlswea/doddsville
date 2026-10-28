//! `dv list`: one line per journal transaction.

const std = @import("std");
const App = @import("../App.zig");
const f = @import("../format.zig");
const ledger_cmd = @import("ledger.zig");

// Binding NULL disables a filter. A trade's total is its Kurswert, a
// dividend's or interest's the gross income; anything else shows its size.
const rows_sql =
    \\SELECT t.id, t.date, t.description,
    \\  (SELECT a.name FROM posting p JOIN ledger_account a ON a.id = p.account
    \\     WHERE p.txn = t.id AND a.kind IN ('asset', 'liability') AND NOT p.fee
    \\     ORDER BY p.security IS NOT NULL, p.id LIMIT 1),
    \\  (SELECT s.name FROM posting p JOIN security s ON s.id = p.security WHERE p.txn = t.id ORDER BY p.id LIMIT 1),
    \\  (SELECT ABS(SUM(p.quantity)) FROM posting p WHERE p.txn = t.id AND p.quantity IS NOT NULL),
    \\  COALESCE(NULLIF(ABS((SELECT SUM(p.amount) FROM posting p JOIN ledger_account a ON a.id = p.account
    \\     WHERE p.txn = t.id AND NOT p.fee AND (a.kind = 'income' OR p.quantity IS NOT NULL))), 0),
    \\   (SELECT SUM(p.amount) FROM posting p WHERE p.txn = t.id AND p.amount > 0 AND NOT p.fee)),
    \\  (SELECT SUM(p.amount) FROM posting p WHERE p.txn = t.id AND p.fee),
    \\  (SELECT SUM(p.amount) FROM posting p JOIN ledger_account a ON a.id = p.account
    \\     WHERE p.txn = t.id AND a.name IN (?3, ?4, ?5, ?6)),
    \\  (SELECT GROUP_CONCAT(paperless_id) FROM txn_document WHERE txn = t.id)
    \\FROM txn t
    \\WHERE (?1 IS NULL OR EXISTS (SELECT 1 FROM posting p JOIN ledger_account a ON a.id = p.account
    \\         WHERE p.txn = t.id AND a.name LIKE ?1))
    \\  AND (?2 IS NULL OR t.description = ?2)
    \\ORDER BY t.date DESC, t.id DESC
;

const row_scratch_size = 16 * 1024;

pub fn run(app: *App, account: ?[]const u8, txn_type: ?[]const u8) !void {
    try ledger_cmd.sync(app);

    var pattern_buf: [256]u8 = undefined;
    const pattern: ?[]const u8 = if (account) |acc|
        std.fmt.bufPrint(&pattern_buf, "%{s}%", .{acc}) catch return error.AccountFilterTooLong
    else
        null;

    const names = app.config.ledger.accounts;
    var st = try app.db.prepare(rows_sql);
    defer st.finalize();
    try st.bindAll(.{ pattern, txn_type, names.kapest, names.soli, names.kist, names.quellensteuer });

    const paperless_url = std.mem.trimEnd(u8, app.config.paperless.url orelse "", "/");
    var scratch_buf: [row_scratch_size]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&scratch_buf);

    var any = false;
    while (try st.step()) {
        scratch.reset();
        const a = scratch.allocator();
        if (!any) try header(app, a);
        any = true;

        // Text is borrowed from SQLite and only valid until the next step.
        const id = st.int(0);
        const date = st.textRef(1) orelse "";
        const kind = st.textRef(2) orelse "";
        const account_name = withoutRoot(st.textRef(3) orelse "-");
        const security_full = st.textRef(4);
        const qty = st.optInt(5);
        const total = st.optInt(6);
        const fees = st.optInt(7);
        const taxes = st.optInt(8);
        const doc_ids = st.textRef(9);

        const sec_first = if (security_full) |s| s[0 .. std.mem.indexOfScalar(u8, s, ' ') orelse s.len] else "";
        const security = if (sec_first.len > 0) sec_first else "-";
        const qty_str = if (qty) |q| (if (q != 0) try f.quantity(a, q) else "-") else "-";
        const unit: ?i64 = if (qty != null and qty.? != 0 and total != null)
            @intCast(@divTrunc(@as(i128, total.?) * f.quantity_scale + @divTrunc(qty.?, 2), qty.?))
        else
            null;

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
            try f.left(a, account_name, 20),
            try f.left(a, kind, 10),
            try f.left(a, security, 20),
            try f.left(a, qty_str, 9),
            try f.left(a, try centsOrDash(a, unit), 10),
            try f.left(a, try centsOrDash(a, total), 12),
        });
        try app.print("{s} {s} {s}\n", .{ try f.left(a, try centsOrDash(a, fees), 8), try f.left(a, try centsOrDash(a, taxes), 8), docs });
    }

    if (!any) try app.line("No transactions found.");
}

fn header(app: *App, a: std.mem.Allocator) !void {
    try app.print("{s}{s} {s} {s} {s} {s} {s} {s} {s} ", .{
        f.BOLD,
        try f.left(a, "ID", 5),
        try f.left(a, "Date", 12),
        try f.left(a, "Account", 20),
        try f.left(a, "Type", 10),
        try f.left(a, "Security", 20),
        try f.left(a, "Qty", 9),
        try f.left(a, "Unit", 10),
        try f.left(a, "Total", 12),
    });
    try app.print("{s} {s} Docs{s}\n", .{ try f.left(a, "Fees", 8), try f.left(a, "Taxes", 8), f.RESET });
    try app.line(f.rep("-", 132));
}

/// "Assets:Scalable:Cash" → "Scalable:Cash".
fn withoutRoot(name: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, name, ':') orelse return name;
    return name[colon + 1 ..];
}

fn centsOrDash(a: std.mem.Allocator, v: ?i64) ![]const u8 {
    const x = v orelse return "-";
    return if (x != 0) f.cents(a, x) else "-";
}
