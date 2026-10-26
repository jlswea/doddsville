//! `dv import`: the terminal front end for importer.zig. It asks every
//! question (account, unknown securities, LLM fallback, edits, confirmation);
//! nothing is written without confirmation.

const std = @import("std");
const App = @import("../App.zig");
const f = @import("../format.zig");
const importer = @import("../importer.zig");
const lookup = @import("../lookup.zig");
const ollama = @import("../ollama.zig");
const paperless = @import("../paperless.zig");
const parsers = @import("../parsers/parsers.zig");
const pdf = @import("../pdf/pdf.zig");
const ui = @import("../ui.zig");

const Row = importer.Row;

pub const Options = struct {
    pdf_file: []const u8,
    account: ?[]const u8 = null,
    parser: ?[]const u8 = null,
    model: ?[]const u8 = null,
    dry_run: bool = false,
    no_upload: bool = false,
};

/// Reports problems itself and returns null.
pub fn extract(app: *App, path: []const u8) !?[]const pdf.Page {
    switch (try importer.read(app.a, app.io, path)) {
        .pages => |pages| return pages,
        .not_found => try app.print("{s}PDF file not found: {s}{s}\n", .{ f.RED, path, f.RESET }),
        .too_large => try app.print("{s}PDF is larger than {d} KiB: {s}{s}\n", .{ f.RED, importer.max_pdf_size / 1024, path, f.RESET }),
        .unreadable => |why| try app.print("{s}Could not read {s}: {s}{s}\n", .{ f.RED, path, why, f.RESET }),
    }
    return null;
}

pub fn raw(app: *App, path: []const u8) !void {
    const pages = (try extract(app, path)) orelse return error.Reported;
    for (pages, 1..) |page, i| {
        try app.print("--- Page {d} ---\n", .{i});
        for (page.lines) |l| try app.line(l.text);
    }
}

pub fn run(app: *App, opts: Options) !void {
    const pages = (try extract(app, opts.pdf_file)) orelse return error.Reported;

    const result = (try parse(app, pages, opts)) orelse return error.Reported;
    try app.print("  {s}✓{s} Parsed with {s} parser\n", .{ f.GREEN, f.RESET, result.parser });
    try printSkipped(app, result.skipped);
    if (result.txns.len == 0) {
        try app.print("{s}No transactions found in document.{s}\n", .{ f.YELLOW, f.RESET });
        return;
    }

    var rows = try importer.rows(app.a, result);

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

    const duplicates = importer.duplicates(rows.items);
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
    const ids = try importer.commit(app.db, app.a, rows.items, account.id);
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

    const plan = (try importer.uploadPlan(app.a, result, std.fs.path.stem(path), lists.correspondents, lists.doc_types, lists.tags)) orelse {
        try app.print("\n{s}✗ Cannot upload: tag 'dv' not found in paperless-ngx.{s}\n", .{ f.RED, f.RESET });
        try app.line("  Please create the 'dv' tag in paperless before uploading documents.");
        return manualHint(app, path);
    };
    var meta = plan.metadata;
    if (meta.correspondent_id == null) {
        try app.print("\n{s}⚠ No correspondent matching '{s}' found.{s}\n", .{ f.YELLOW, result.correspondent, f.RESET });
        try app.line("  Please set the correspondent manually in the metadata editor.");
    }
    try ui.previewMetadata(app, meta, lists);
    if (std.ascii.eqlIgnoreCase(f.strip(try app.input("\nEdit metadata before upload? (y/N) ")), "y"))
        meta = try ui.editDocumentMetadata(app, meta, lists);

    try app.print("\nUploading {s} to paperless-ngx...\n", .{std.fs.path.basename(path)});
    const doc_id = cl.upload(path, plan.dv_tag, meta, plan.remove_tags) catch |err| {
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

/// Deterministic parsers first; the LLM only when none can read the document
/// and the user agrees (or asked for it with --parser llm).
fn parse(app: *App, pages: []const pdf.Page, opts: Options) !?parsers.Result {
    const forced_llm = if (opts.parser) |n| std.mem.eql(u8, n, parsers.llm.name) else false;
    if (!forced_llm) {
        switch (try importer.parse(app.a, pages, opts.parser)) {
            .ok => |r| return r,
            .unknown_parser => {
                try app.print("{s}Unknown parser '{s}'. Available: {s}{s}\n", .{ f.RED, opts.parser.?, try importer.parserNames(app.a), f.RESET });
                return null;
            },
            .no_parser => try app.print("{s}No parser recognises this document.{s}\n", .{ f.YELLOW, f.RESET }),
            .refused => |x| try app.print("{s}The {s} parser could not read this document: {s}.{s}\n", .{ f.YELLOW, x.parser, x.reason, f.RESET }),
        }
        if (opts.parser != null) return null;
    }

    var client: ollama.Client = .init(app, opts.model);
    if (!forced_llm) {
        const q = try app.fmt("Let the local LLM ({s} at {s}) try instead? (y/N) ", .{ client.model, client.url });
        if (!std.ascii.eqlIgnoreCase(f.strip(try app.input(q)), "y")) {
            try app.line("Run with --raw to see the extracted text.");
            return null;
        }
    }
    try app.print("Asking {s}, this can take a minute...\n", .{client.model});
    switch (try importer.askLlm(app.a, &client, pages)) {
        .ok => |x| {
            try app.print("{s}⚠ These come from the LLM, not a parser: check every field.{s}\n", .{ f.YELLOW, f.RESET });
            if (x.rejected > 0) try app.print("{s}  {d} transaction(s) from the LLM were invalid and dropped.{s}\n", .{ f.YELLOW, x.rejected, f.RESET });
            return x.result;
        },
        .unavailable => |msg| try app.print("{s}{s}{s}\n", .{ f.RED, msg, f.RESET }),
        .invalid => |why| try app.print("{s}{s}. Try again or another --model.{s}\n", .{ f.RED, why, f.RESET }),
    }
    return null;
}

fn printSkipped(app: *App, skipped: []const parsers.Skipped) !void {
    if (skipped.len == 0) return;
    try app.print("\n{s}Not importable (no matching transaction type), record manually if needed:{s}\n", .{ f.YELLOW, f.RESET });
    for (skipped) |s| {
        const d = if (s.date) |x| try x.iso(app.a) else "";
        try app.print("  {s}  {s}  {s}\n", .{ try f.left(app.a, d, 10), try f.right(app.a, try f.cents(app.a, s.amount), 12), s.description });
    }
}

/// Unknown securities are the user's call: create them from the document's
/// ISIN, search by name, or drop the row.
fn resolve(app: *App, rows: *std.ArrayList(Row), account_id: i64) !void {
    try importer.check(app.db, rows.items, account_id);
    var changed = false;
    var i: usize = 0;
    while (i < rows.items.len) {
        const r = &rows.items[i];
        if (!r.needsSecurity()) {
            i += 1;
            continue;
        }
        if (r.isin != null and r.security.len > 0) {
            const q = try app.fmt("Security {s} ({s}) is not in the database. Add it? (y/N) ", .{ r.security, r.isin.? });
            if (std.ascii.eqlIgnoreCase(f.strip(try app.input(q)), "y")) try importer.createSecurity(app.db, r);
        } else if (r.security.len > 0) {
            if (try lookup.getOrPromptSecurity(app, r.security)) |sec| r.security_id = sec.id;
        }
        if (r.needsSecurity()) {
            try app.print("{s}Skipping transaction (security not found): {s}{s}\n", .{ f.YELLOW, r.isin orelse r.security, f.RESET });
            _ = rows.orderedRemove(i);
            continue;
        }
        changed = true;
        i += 1;
    }
    if (changed) try importer.check(app.db, rows.items, account_id);
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
        const sec = if (r.hasSecurity()) try importer.label(app.db, a, r) else "-";
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
        if (r.oversells())
            try app.print("    {s}sells {s} but only {s} are held{s}\n", .{ f.YELLOW, try f.quantity(a, r.quantity), try f.quantity(a, r.held.?), f.RESET });
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
        const shown = try importer.label(app.db, app.a, r.*);
        const after = (try ui.editTransaction(app, .{
            .type = @tagName(r.kind),
            .date = r.date,
            .security = shown,
            .quantity = r.quantity,
            .unit_price_cents = r.unit,
            .cost_cents = r.cost,
            .currency = r.currency,
            .exchange_rate = r.exchange_rate,
        })) orelse {
            _ = rows.orderedRemove(n - 1);
            continue;
        };
        importer.applyEdit(r, shown, .{
            .kind = std.meta.stringToEnum(parsers.Kind, after.type) orelse r.kind,
            .date = after.date,
            .security = after.security,
            .quantity = after.quantity,
            .unit = after.unit_price_cents,
            .cost = after.cost_cents,
            .currency = after.currency,
            .exchange_rate = after.exchange_rate,
        });
        try resolve(app, rows, account_id);
    }
}
