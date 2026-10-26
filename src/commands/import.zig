//! Port of commands/import_cmd.py: broker PDFs into transactions. Parsing is
//! deterministic (src/parsers); nothing is written without confirmation.

const std = @import("std");
const App = @import("../App.zig");
const f = @import("../format.zig");
const lookup = @import("../lookup.zig");
const paperless = @import("../paperless.zig");
const parsers = @import("../parsers/parsers.zig");
const pdf = @import("../pdf/pdf.zig");
const ui = @import("../ui.zig");

pub const max_pdf_size = 1024 * 1024;
/// Caps each decoded PDF stream; page contents of the supported statements are under 100 KiB.
const decode_limit = 512 * 1024;

pub const Options = struct {
    pdf_file: []const u8,
    account: ?[]const u8 = null,
    parser: ?[]const u8 = null,
    dry_run: bool = false,
    no_upload: bool = false,
};

/// Reports problems itself and returns null.
pub fn extract(app: *App, path: []const u8) !?[]const pdf.Page {
    const src = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.a, .limited(max_pdf_size)) catch |err| switch (err) {
        error.FileNotFound => {
            try app.print("{s}PDF file not found: {s}{s}\n", .{ f.RED, path, f.RESET });
            return null;
        },
        error.StreamTooLong => {
            try app.print("{s}PDF is larger than {d} KiB: {s}{s}\n", .{ f.RED, max_pdf_size / 1024, path, f.RESET });
            return null;
        },
        else => return err,
    };
    return pdf.extract(app.a, src, decode_limit) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => {
            try app.print("{s}Could not read {s}: {s}{s}\n", .{ f.RED, path, @errorName(err), f.RESET });
            return null;
        },
    };
}

pub fn raw(app: *App, path: []const u8) !void {
    const pages = (try extract(app, path)) orelse return error.Reported;
    for (pages, 1..) |page, i| {
        try app.print("--- Page {d} ---\n", .{i});
        for (page.lines) |l| try app.line(l.text);
    }
}

/// One candidate transaction as shown and edited before import.
const Row = struct {
    kind: parsers.Kind,
    date: []const u8,
    isin: ?[]const u8,
    security: []const u8,
    security_id: ?i64 = null,
    quantity: i64,
    unit: i64,
    total: i64,
    cost: i64,
    currency: []const u8,
    /// Existing transaction that looks like the same booking.
    duplicate_of: ?i64 = null,
    /// Shares held before this import, for sells.
    held: ?i64 = null,

    fn hasSecurity(r: Row) bool {
        return r.kind == .buy or r.kind == .sell or r.kind == .dividend;
    }
};

fn toRow(app: *App, t: parsers.Txn) !Row {
    return .{
        .kind = t.kind,
        .date = try t.date.iso(app.a),
        .isin = t.isin,
        .security = t.security orelse "",
        .quantity = t.quantity,
        // Statements give only the amount; the unit price follows from it.
        .unit = t.unit_price orelse unitFromTotal(t.total, t.quantity),
        .total = t.total,
        .cost = t.cost,
        .currency = try app.a.dupe(u8, &t.currency),
    };
}

fn unitFromTotal(total: i64, quantity: i64) i64 {
    if (quantity <= 0) return total;
    const q = @divTrunc(@as(i128, total) * f.quantity_scale + @divTrunc(quantity, 2), quantity);
    return std.math.cast(i64, q) orelse total;
}

pub fn run(app: *App, opts: Options) !void {
    const pages = (try extract(app, opts.pdf_file)) orelse return error.Reported;

    const parser = if (opts.parser) |name| parsers.byName(name) orelse {
        try app.print("{s}Unknown parser '{s}'. Available: {s}{s}\n", .{ f.RED, name, try parserNames(app), f.RESET });
        return error.Reported;
    } else parsers.match(pages) orelse {
        try app.print("{s}No parser recognises this document.{s}\n", .{ f.YELLOW, f.RESET });
        try app.line("Run with --raw to see the extracted text.");
        return error.Reported;
    };
    var diag: parsers.Diag = .{};
    const result = parser.parse(app.a, pages, &diag) catch |err| switch (err) {
        error.Unrecognized => {
            try app.print("{s}The {s} parser could not read this document: {s}.{s}\n", .{ f.YELLOW, parser.name, diag.reason, f.RESET });
            try app.line("Run with --raw to see the extracted text.");
            return error.Reported;
        },
        else => return err,
    };
    try app.print("  {s}✓{s} Parsed with {s} parser\n", .{ f.GREEN, f.RESET, result.parser });
    try printSkipped(app, result.skipped);
    if (result.txns.len == 0) {
        try app.print("{s}No transactions found in document.{s}\n", .{ f.YELLOW, f.RESET });
        return;
    }

    var rows: std.ArrayList(Row) = .empty;
    for (result.txns) |t| try rows.append(app.a, try toRow(app, t));

    const account = (try lookup.getOrPromptAccount(app, opts.account)) orelse return;
    try resolve(app, &rows, account.id);
    if (rows.items.len == 0) {
        try app.print("{s}No valid transactions remaining after security resolution.{s}\n", .{ f.RED, f.RESET });
        return;
    }
    try preview(app, rows.items, account.name.slice());

    if (std.ascii.eqlIgnoreCase(f.strip(try app.input("\nEdit transactions? (y/N) ")), "y")) {
        try editRows(app, &rows, account.id);
        if (rows.items.len == 0) {
            try app.print("{s}No transactions remaining after editing.{s}\n", .{ f.RED, f.RESET });
            return;
        }
        try preview(app, rows.items, account.name.slice());
    }

    if (opts.dry_run) {
        try app.print("\n{s}Dry run - no transactions inserted.{s}\n", .{ f.YELLOW, f.RESET });
        return;
    }

    var duplicates: usize = 0;
    for (rows.items) |r| duplicates += @intFromBool(r.duplicate_of != null);
    if (duplicates == rows.items.len) {
        try app.print("\n{s}All transactions are already recorded; nothing to import.{s}\n", .{ f.YELLOW, f.RESET });
        return;
    }
    const prompt = if (duplicates > 0)
        try app.fmt("\nImport {d} transaction(s), skipping {d} possible duplicate(s)? (y/N) ", .{ rows.items.len - duplicates, duplicates })
    else
        "\nImport these transactions? (y/N) ";
    if (!std.ascii.eqlIgnoreCase(f.strip(try app.input(prompt)), "y")) {
        try app.line("Import cancelled.");
        return;
    }
    const ids = try insert(app, rows.items, account.id);
    try app.print("\n{s}Imported {d} transaction(s).{s}\n", .{ f.GREEN, ids.len, f.RESET });

    if (!opts.no_upload) try upload(app, opts.pdf_file, result, ids);
}

/// Port of step 12 in import_cmd.py: upload the PDF with metadata from the
/// parser, link it to the new transactions and set the backlink field.
fn upload(app: *App, path: []const u8, result: parsers.Result, txn_ids: []const i64) !void {
    var cl = paperless.Client.init(app) catch |err| switch (err) {
        error.NotConfigured => {
            try app.print("\n{s}Paperless not configured - skipping document upload.{s}\n", .{ f.YELLOW, f.RESET });
            return;
        },
        else => return err,
    };
    defer cl.deinit();

    try app.line("\nFetching Paperless metadata options...");
    const lists: ui.Lists = fetchLists(&cl) catch |err| {
        try app.print("  {s}Warning: Could not fetch Paperless metadata options: {s}{s}\n", .{ f.YELLOW, cl.describe(err), f.RESET });
        return manualHint(app, path);
    };

    var dv_tag_id: ?i64 = null;
    var remove_tag_ids: std.ArrayList(i64) = .empty;
    for (lists.tags) |t| {
        if (std.mem.eql(u8, t.name, "dv")) {
            dv_tag_id = t.id;
        } else if (std.mem.eql(u8, t.name, "todo") or std.mem.eql(u8, t.name, "inbox")) try remove_tag_ids.append(app.a, t.id);
    }
    const dv_tag = dv_tag_id orelse {
        try app.print("\n{s}✗ Cannot upload: tag 'dv' not found in paperless-ngx.{s}\n", .{ f.RED, f.RESET });
        try app.line("  Please create the 'dv' tag in paperless before uploading documents.");
        return manualHint(app, path);
    };

    const stem = std.fs.path.stem(path);
    var meta: paperless.DocumentMetadata = .{
        .title = stem,
        .created = if (result.created) |d| try d.iso(app.a) else "",
        .correspondent_id = byNameContains(lists.correspondents, result.correspondent),
        .document_type_id = byName(lists.doc_types, result.document_type),
        .tag_ids = try app.a.dupe(i64, &.{dv_tag}),
    };
    if (meta.correspondent_id == null) {
        try app.print("\n{s}⚠ No correspondent matching '{s}' found.{s}\n", .{ f.YELLOW, result.correspondent, f.RESET });
        try app.line("  Please set the correspondent manually in the metadata editor.");
    }
    try ui.previewMetadata(app, meta, lists);
    if (std.ascii.eqlIgnoreCase(f.strip(try app.input("\nEdit metadata before upload? (y/N) ")), "y"))
        meta = try ui.editDocumentMetadata(app, meta, lists);

    try app.print("\nUploading {s} to paperless-ngx...\n", .{std.fs.path.basename(path)});
    const doc_id = cl.upload(path, dv_tag, meta, remove_tag_ids.items) catch |err| {
        try app.print("  {s}Warning: Could not upload to paperless: {s}{s}\n", .{ f.YELLOW, cl.describe(err), f.RESET });
        return manualHint(app, path);
    };
    try app.print("  {s}✓{s} Uploaded as document {d}\n", .{ f.GREEN, f.RESET, doc_id });
    for (txn_ids) |tid| try paperless.insertTransactionDocuments(app, tid, &.{doc_id});
    try app.print("  Linked document to {d} transaction(s)\n", .{txn_ids.len});
    try paperless.backlink(app, &.{doc_id}, txn_ids);
}

fn fetchLists(cl: *paperless.Client) !ui.Lists {
    return .{
        .correspondents = try cl.fetchNamed("correspondents"),
        .doc_types = try cl.fetchNamed("document_types"),
        .storage_paths = try cl.fetchNamed("storage_paths"),
        .tags = try cl.fetchNamed("tags"),
    };
}

fn manualHint(app: *App, path: []const u8) !void {
    try app.print("  You can manually link later with: dv doc add <transaction_id> {s}\n", .{path});
}

/// resolve_correspondent: either name contains the other, case-insensitively.
fn byNameContains(items: []const paperless.Named, name: []const u8) ?i64 {
    if (name.len == 0) return null;
    for (items) |it| {
        if (std.ascii.findIgnoreCase(it.name, name) != null or std.ascii.findIgnoreCase(name, it.name) != null) return it.id;
    }
    return null;
}

fn byName(items: []const paperless.Named, name: []const u8) ?i64 {
    for (items) |it| if (std.ascii.eqlIgnoreCase(it.name, name)) return it.id;
    return null;
}

/// All rows in one database transaction; returns the new transaction ids.
fn insert(app: *App, rows: []const Row, account_id: i64) ![]const i64 {
    var ids: std.ArrayList(i64) = .empty;
    try app.db.exec("BEGIN");
    errdefer app.db.exec("ROLLBACK") catch {};
    for (rows) |r| {
        if (r.duplicate_of != null) continue;
        const kind = @tagName(r.kind);
        switch (r.kind) {
            .buy, .sell => try app.db.run(
                \\INSERT INTO "transaction"
                \\   (account, security, type, quantity, unit_value, total_value, cost, date, currency, exchange_rate)
                \\   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1.0)
            , .{ account_id, r.security_id.?, kind, r.quantity, r.unit, r.total, r.cost, r.date, r.currency }),
            .dividend => try app.db.run(
                \\INSERT INTO "transaction"
                \\   (account, security, type, total_value, cost, date, currency, exchange_rate)
                \\   VALUES (?, ?, ?, ?, ?, ?, ?, 1.0)
            , .{ account_id, r.security_id.?, kind, r.total, r.cost, r.date, r.currency }),
            .interest, .deposit, .withdrawal => try app.db.run(
                \\INSERT INTO "transaction"
                \\   (account, type, total_value, cost, date, currency, exchange_rate)
                \\   VALUES (?, ?, ?, ?, ?, ?, 1.0)
            , .{ account_id, kind, r.total, r.cost, r.date, r.currency }),
        }
        try ids.append(app.a, app.db.lastInsertRowId());
        // Most securities were seeded without a name; the document has one.
        if (r.security_id) |sid| if (r.security.len > 0) try app.db.run(
            \\UPDATE security SET name = ? WHERE id = ? AND TRIM(COALESCE(name, '')) = ''
        , .{ r.security, sid });
    }
    try app.db.exec("COMMIT");
    return ids.items;
}

fn parserNames(app: *App) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (parsers.all, 0..) |p, i| {
        if (i > 0) try out.appendSlice(app.a, ", ");
        try out.appendSlice(app.a, p.name);
    }
    return out.items;
}

fn printSkipped(app: *App, skipped: []const parsers.Skipped) !void {
    if (skipped.len == 0) return;
    try app.print("\n{s}Not importable (no matching transaction type), record manually if needed:{s}\n", .{ f.YELLOW, f.RESET });
    for (skipped) |s| {
        const d = if (s.date) |x| try x.iso(app.a) else "";
        try app.print("  {s}  {s}  {s}\n", .{ try f.left(app.a, d, 10), try f.right(app.a, try f.cents(app.a, s.amount), 12), s.description });
    }
}

/// Securities by ISIN, falling back to name search; flags duplicates and
/// sells beyond the current holdings. Rows without a security are dropped.
fn resolve(app: *App, rows: *std.ArrayList(Row), account_id: i64) !void {
    var i: usize = 0;
    while (i < rows.items.len) {
        const r = &rows.items[i];
        if (r.hasSecurity() and r.security_id == null) {
            r.security_id = try securityFor(app, r.*);
            if (r.security_id == null) {
                try app.print("{s}Skipping transaction (security not found): {s}{s}\n", .{ f.YELLOW, r.isin orelse r.security, f.RESET });
                _ = rows.orderedRemove(i);
                continue;
            }
        }
        r.duplicate_of = try findDuplicate(app, account_id, r.*);
        r.held = if (r.kind == .sell) try holdings(app, account_id, r.security_id.?, r.duplicate_of) else null;
        i += 1;
    }
}

fn securityFor(app: *App, r: Row) !?i64 {
    if (r.isin) |isin| {
        var st = try app.db.prepare("SELECT id FROM security WHERE isin = ? LIMIT 2");
        defer st.finalize();
        try st.bindAll(.{isin});
        if (try st.step()) {
            const id = st.int(0);
            if (!try st.step()) return id;
        }
    }
    if (r.isin) |isin| if (r.security.len > 0) {
        const q = try app.fmt("Security {s} ({s}) is not in the database. Add it? (y/N) ", .{ r.security, isin });
        if (std.ascii.eqlIgnoreCase(f.strip(try app.input(q)), "y")) {
            try app.db.run("INSERT INTO security (isin, name) VALUES (?, ?)", .{ isin, r.security });
            return app.db.lastInsertRowId();
        }
        return null;
    };
    if (r.security.len > 0) if (try lookup.getOrPromptSecurity(app, r.security)) |s| return s.id;
    return null;
}

/// Same type, quantity and amount within ten days: earlier records sometimes
/// carry the value date instead of the trade date.
fn findDuplicate(app: *App, account_id: i64, r: Row) !?i64 {
    var st = try app.db.prepare(
        \\SELECT id FROM "transaction"
        \\WHERE account = ? AND type = ? AND total_value = ? AND COALESCE(quantity, ?) = ?
        \\  AND ABS(julianday(date) - julianday(?)) <= 10
        \\ORDER BY ABS(julianday(date) - julianday(?)) LIMIT 1
    );
    defer st.finalize();
    try st.bindAll(.{ account_id, @tagName(r.kind), r.total, f.quantity_scale, r.quantity, r.date, r.date });
    return if (try st.step()) st.int(0) else null;
}

/// Shares held, not counting `except` (the recorded copy of a re-imported sell).
fn holdings(app: *App, account_id: i64, security_id: i64, except: ?i64) !i64 {
    var st = try app.db.prepare(
        \\SELECT COALESCE(SUM(CASE WHEN type = 'buy' THEN quantity WHEN type = 'sell' THEN -quantity ELSE 0 END), 0)
        \\FROM "transaction" WHERE account = ? AND security = ? AND id IS NOT ?
    );
    defer st.finalize();
    try st.bindAll(.{ account_id, security_id, except });
    _ = try st.step();
    return st.int(0);
}

/// The database name; many securities were seeded with an ISIN only, so the
/// document's name and then the ISIN stand in.
fn securityLabel(app: *App, r: Row) ![]const u8 {
    if (r.security_id) |id| {
        var st = try app.db.prepare("SELECT name, isin FROM security WHERE id = ?");
        defer st.finalize();
        try st.bindAll(.{id});
        if (try st.step()) {
            const name = f.strip(st.textRef(0) orelse "");
            if (name.len > 0) return app.a.dupe(u8, name);
            if (r.security.len > 0) return r.security;
            if (st.textRef(1)) |isin| return app.a.dupe(u8, isin);
        }
    }
    return if (r.security.len > 0) r.security else "-";
}

fn preview(app: *App, rows: []const Row, account: []const u8) !void {
    const a = app.a;
    try app.print("\n{s}Transactions to import into {s}:{s}\n", .{ f.BOLD, account, f.RESET });
    try app.print("{s} {s} {s} {s} {s} {s} {s} {s}\n", .{
        try f.left(a, "#", 3),     try f.left(a, "Type", 9),   try f.left(a, "Date", 11),   try f.left(a, "Security", 28),
        try f.right(a, "Qty", 10), try f.right(a, "Unit", 10), try f.right(a, "Total", 12), try f.right(a, "Cost", 8),
    });
    try app.line(f.rep("-", 97));
    for (rows, 1..) |r, i| {
        const sec = if (r.hasSecurity()) try securityLabel(app, r) else "-";
        try app.print("{s} {s} {s} {s} {s} {s} {s} {s}\n", .{
            try f.left(a, try f.int(a, @intCast(i)), 3),
            try f.left(a, @tagName(r.kind), 9),
            try f.left(a, r.date, 11),
            try f.left(a, sec[0..@min(sec.len, prefixLen(sec, 28))], 28),
            try f.right(a, if (r.hasSecurity() and r.kind != .dividend) try f.quantity(a, r.quantity) else "-", 10),
            try f.right(a, if (r.kind == .buy or r.kind == .sell) try f.centsIn(a, r.unit, r.currency) else "-", 10),
            try f.right(a, try f.centsIn(a, r.total, r.currency), 12),
            try f.right(a, if (r.cost != 0) try f.cents(a, r.cost) else "-", 8),
        });
        if (r.duplicate_of) |d|
            try app.print("    {s}possible duplicate of transaction {d}; it will be skipped{s}\n", .{ f.YELLOW, d, f.RESET });
        if (r.held) |h| if (r.quantity > h)
            try app.print("    {s}sells {s} but only {s} are held{s}\n", .{ f.YELLOW, try f.quantity(a, r.quantity), try f.quantity(a, h), f.RESET });
    }
}

/// Byte length of the first `n` code points of `s`.
fn prefixLen(s: []const u8, n: usize) usize {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    var count: usize = 0;
    while (count < n) : (count += 1) _ = it.nextCodepointSlice() orelse break;
    return it.i;
}

fn editRows(app: *App, rows: *std.ArrayList(Row), account_id: i64) !void {
    while (rows.items.len > 0) {
        const choice = f.strip(try app.input(try app.fmt("\nTransaction to edit (1-{d}, Enter to finish): ", .{rows.items.len})));
        if (choice.len == 0) return;
        const n = std.fmt.parseInt(usize, choice, 10) catch 0;
        if (n < 1 or n > rows.items.len) {
            try app.print("{s}Invalid choice{s}\n", .{ f.RED, f.RESET });
            continue;
        }
        const r = &rows.items[n - 1];
        const sec = try securityLabel(app, r.*);
        const before: ui.EditTxn = .{
            .type = @tagName(r.kind),
            .date = r.date,
            .security = sec,
            .quantity = r.quantity,
            .unit_price_cents = r.unit,
            .cost_cents = r.cost,
            .currency = r.currency,
            .exchange_rate = 1.0,
        };
        const after = (try ui.editTransaction(app, before)) orelse {
            _ = rows.orderedRemove(n - 1);
            continue;
        };
        if (std.meta.stringToEnum(parsers.Kind, after.type)) |k| r.kind = k;
        r.date = after.date;
        r.cost = after.cost_cents;
        r.currency = after.currency;
        if (after.quantity != r.quantity or after.unit_price_cents != r.unit) {
            r.quantity = after.quantity;
            r.unit = after.unit_price_cents;
            r.total = f.lineTotal(r.quantity, r.unit) orelse r.total;
        }
        if (!std.mem.eql(u8, after.security, sec)) {
            r.isin = null;
            r.security = after.security;
            r.security_id = null;
        }
        if (!r.hasSecurity()) r.security_id = null;
        var one: std.ArrayList(Row) = .empty;
        try one.append(app.a, r.*);
        try resolve(app, &one, account_id);
        if (one.items.len == 0) {
            _ = rows.orderedRemove(n - 1);
        } else r.* = one.items[0];
    }
}

test "unit price derived from a statement amount" {
    try std.testing.expectEqual(@as(i64, 9759), unitFromTotal(50000, 5_123_456));
    try std.testing.expectEqual(@as(i64, 9840), unitFromTotal(118080, 12_000_000));
}

test "paperless names resolve like the Python helpers" {
    const items = [_]paperless.Named{ .{ .id = 1, .name = "Scalable" }, .{ .id = 2, .name = "Abrechnung" } };
    try std.testing.expectEqual(@as(?i64, 1), byNameContains(&items, "Scalable Capital"));
    try std.testing.expectEqual(@as(?i64, null), byNameContains(&items, ""));
    try std.testing.expectEqual(@as(?i64, 2), byName(&items, "abrechnung"));
    try std.testing.expectEqual(@as(?i64, null), byName(&items, "Kontoauszug"));
}
