//! The PDF import without a user interface: candidate rows, the check against
//! the ledger, edits and the final commit. Front ends (the CLI, later a GUI)
//! drive these steps and own every question to the user.

const std = @import("std");
const Allocator = std.mem.Allocator;

const bookings = @import("bookings.zig");
const f = @import("format.zig");
const ollama = @import("ollama.zig");
const paperless = @import("paperless.zig");
const parsers = @import("parsers/parsers.zig");
const pdf = @import("pdf/pdf.zig");
const securities = @import("securities.zig");
const sqlite = @import("sqlite.zig");

pub const max_pdf_size = 1024 * 1024;
/// Caps each decoded PDF stream; page contents of the supported statements are under 100 KiB.
const decode_limit = 512 * 1024;

pub const Read = union(enum) {
    pages: []const pdf.Page,
    not_found,
    too_large,
    /// Error name from the PDF reader.
    unreadable: []const u8,
};

pub fn read(a: Allocator, io: std.Io, path: []const u8) !Read {
    const src = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_pdf_size)) catch |err| switch (err) {
        error.FileNotFound => return .not_found,
        error.StreamTooLong => return .too_large,
        else => return err,
    };
    return .{ .pages = pdf.extract(a, src, decode_limit) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .unreadable = @errorName(err) },
    } };
}

pub const Parsed = union(enum) {
    ok: parsers.Result,
    unknown_parser,
    no_parser,
    /// A parser claimed the document but its checks failed.
    refused: struct { parser: []const u8, reason: []const u8 },
};

/// Deterministic parsers only: the named one, or the first that claims the pages.
pub fn parse(a: Allocator, pages: []const pdf.Page, parser_name: ?[]const u8) Allocator.Error!Parsed {
    const parser = if (parser_name) |n| parsers.byName(n) orelse return .unknown_parser else parsers.match(pages) orelse return .no_parser;
    var diag: parsers.Diag = .{};
    const r = parser.parse(a, pages, &diag) catch |err| switch (err) {
        error.Unrecognized => return .{ .refused = .{ .parser = parser.name, .reason = diag.reason } },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .ok = r };
}

pub const Llm = union(enum) {
    ok: struct { result: parsers.Result, rejected: usize },
    /// Ollama could not be reached or answered with an error.
    unavailable: []const u8,
    /// The answer was not usable.
    invalid: []const u8,
};

/// The last resort; the result goes through the same row checks as any other.
pub fn askLlm(a: Allocator, client: *ollama.Client, pages: []const pdf.Page) !Llm {
    const answer = client.generate(try parsers.llm.prompt(a, pages)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .unavailable = client.last_error },
    };
    var rejected: usize = 0;
    var diag: parsers.Diag = .{};
    const r = parsers.llm.parseAnswer(a, answer, &rejected, &diag) catch |err| switch (err) {
        error.Unrecognized => return .{ .invalid = diag.reason },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .ok = .{ .result = r, .rejected = rejected } };
}

/// "scalable_trade, scalable_statement, llm"
pub fn parserNames(a: Allocator) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (parsers.all) |p| {
        try out.appendSlice(a, p.name);
        try out.appendSlice(a, ", ");
    }
    try out.appendSlice(a, parsers.llm.name);
    return out.items;
}

/// One candidate transaction as shown and edited before import.
pub const Row = struct {
    kind: parsers.Kind,
    date: []const u8,
    isin: ?[]const u8,
    /// The document's name for the security.
    security: []const u8,
    security_id: ?i64 = null,
    quantity: i64,
    unit: i64,
    total: i64,
    cost: i64,
    currency: []const u8,
    exchange_rate: f64,
    /// Existing transaction that looks like the same booking.
    duplicate_of: ?i64 = null,
    /// Shares held before this import, for sells.
    held: ?i64 = null,

    pub fn hasSecurity(r: Row) bool {
        return r.kind == .buy or r.kind == .sell or r.kind == .dividend;
    }

    /// The front end has to create, search or drop this row before commit.
    pub fn needsSecurity(r: Row) bool {
        return r.hasSecurity() and r.security_id == null;
    }

    pub fn oversells(r: Row) bool {
        return if (r.held) |h| r.quantity > h else false;
    }

    fn entry(r: Row) bookings.Entry {
        return .{
            .kind = std.meta.stringToEnum(bookings.Entry.Kind, @tagName(r.kind)).?,
            .date = r.date,
            .security = if (r.hasSecurity()) r.security_id else null,
            .quantity = if (r.kind == .buy or r.kind == .sell) r.quantity else 0,
            .total = r.total,
            .cost = r.cost,
            .currency = r.currency,
            .exchange_rate = r.exchange_rate,
        };
    }
};

pub fn rows(a: Allocator, result: parsers.Result) Allocator.Error!std.ArrayList(Row) {
    var out: std.ArrayList(Row) = .empty;
    for (result.txns) |t| try out.append(a, .{
        .kind = t.kind,
        .date = try t.date.iso(a),
        .isin = t.isin,
        .security = t.security orelse "",
        .quantity = t.quantity,
        // Statements give only the amount; the unit price follows from it.
        .unit = t.unit_price orelse unitFromTotal(t.total, t.quantity),
        .total = t.total,
        .cost = t.cost,
        .currency = try a.dupe(u8, &t.currency),
        .exchange_rate = t.exchange_rate,
    });
    return out;
}

fn unitFromTotal(total: i64, quantity: i64) i64 {
    if (quantity <= 0) return total;
    const q = @divTrunc(@as(i128, total) * f.quantity_scale + @divTrunc(quantity, 2), quantity);
    return std.math.cast(i64, q) orelse total;
}

/// Finds securities by ISIN and flags duplicates and sells beyond the
/// holdings. Rows whose security stays unknown are left for the front end.
pub fn check(b: bookings.Book, rs: []Row, broker: []const u8) !void {
    const names = try b.ledger.broker(b.a, broker);
    for (rs) |*r| {
        if (r.needsSecurity()) if (r.isin) |isin| {
            r.security_id = try securities.byIsin(b.db, isin);
        };
        r.duplicate_of = null;
        r.held = null;
        if (r.needsSecurity()) continue;
        r.duplicate_of = try findDuplicate(b.db, names.cash.?, names.depot.?, r.entry());
        if (r.kind == .sell) r.held = try held(b.db, names.depot.?, r.security_id.?, r.duplicate_of);
    }
}

/// Same kind on the broker's accounts within ten days (earlier records
/// sometimes carry the value date), with the same shares for a trade (and
/// Kurswert for a buy), otherwise the same gross amount.
fn findDuplicate(db: sqlite.Db, cash: []const u8, depot: []const u8, e: bookings.Entry) !?i64 {
    var st = try db.prepare(
        \\SELECT t.id FROM txn t
        \\WHERE t.description = ?1 AND ABS(julianday(t.date) - julianday(?2)) <= 10
        \\  AND EXISTS (SELECT 1 FROM posting p JOIN ledger_account a ON a.id = p.account
        \\                WHERE p.txn = t.id AND a.name IN (?3, ?4))
        \\  AND CASE WHEN ?1 IN ('buy', 'sell')
        \\    THEN EXISTS (SELECT 1 FROM posting p JOIN ledger_account a ON a.id = p.account
        \\           WHERE p.txn = t.id AND a.name = ?4 AND p.security = ?5 AND p.quantity = ?6
        \\             AND (?1 = 'sell' OR p.amount = ?7))
        \\    ELSE EXISTS (SELECT 1 FROM posting p JOIN ledger_account a ON a.id = p.account
        \\           WHERE p.txn = t.id AND a.kind NOT IN ('asset', 'liability') AND NOT p.fee AND ABS(p.amount) = ?7)
        \\  END
        \\ORDER BY ABS(julianday(t.date) - julianday(?2)) LIMIT 1
    );
    defer st.finalize();
    const quantity = if (e.kind == .sell) -e.quantity else e.quantity;
    try st.bindAll(.{ @tagName(e.kind), e.date, cash, depot, e.security, quantity, e.eur() });
    return if (try st.step()) st.int(0) else null;
}

/// Shares in the depot, not counting `except` (the recorded copy of a
/// re-imported sell).
fn held(db: sqlite.Db, depot: []const u8, security: i64, except: ?i64) !i64 {
    var st = try db.prepare(
        \\SELECT COALESCE(SUM(p.quantity), 0) FROM posting p JOIN ledger_account a ON a.id = p.account
        \\WHERE a.name = ? AND p.security = ? AND p.quantity IS NOT NULL AND p.txn IS NOT ?
    );
    defer st.finalize();
    try st.bindAll(.{ depot, security, except });
    _ = try st.step();
    return st.int(0);
}

/// Only for rows whose document gives both an ISIN and a name.
pub fn createSecurity(db: sqlite.Db, r: *Row) !void {
    std.debug.assert(r.needsSecurity() and r.isin != null and r.security.len > 0);
    r.security_id = try securities.add(db, r.isin.?, r.security);
}

pub const Edit = struct {
    kind: parsers.Kind,
    date: []const u8,
    /// The label as shown; a different one means a different security.
    security: []const u8,
    quantity: i64,
    unit: i64,
    cost: i64,
    currency: []const u8,
    exchange_rate: f64,
};

/// Imported totals are exact booking amounts, so the total is recomputed
/// only when quantity or unit price changed. Run `check` again afterwards.
pub fn applyEdit(r: *Row, shown_label: []const u8, e: Edit) void {
    r.kind = e.kind;
    r.date = e.date;
    r.cost = e.cost;
    r.currency = e.currency;
    r.exchange_rate = e.exchange_rate;
    if (e.quantity != r.quantity or e.unit != r.unit) {
        r.quantity = e.quantity;
        r.unit = e.unit;
        r.total = f.lineTotal(r.quantity, r.unit) orelse r.total;
    }
    if (!std.mem.eql(u8, e.security, shown_label)) {
        r.isin = null;
        r.security = e.security;
        r.security_id = null;
    }
    if (!r.hasSecurity()) r.security_id = null;
}

/// The database name; many securities were seeded with an ISIN only, so the
/// document's name and then the ISIN stand in.
pub fn label(db: sqlite.Db, a: Allocator, r: Row) ![]const u8 {
    if (r.security_id) |id| if (try securities.get(db, a, id)) |sec| {
        if (sec.name.len > 0) return sec.name;
        if (r.security.len > 0) return r.security;
        if (sec.isin.len > 0) return sec.isin;
    };
    return if (r.security.len > 0) r.security else "-";
}

pub fn duplicates(rs: []const Row) usize {
    var n: usize = 0;
    for (rs) |r| n += @intFromBool(r.duplicate_of != null);
    return n;
}

/// All non-duplicate rows in one database transaction; returns the new ids.
pub fn commit(b: bookings.Book, rs: []const Row, broker: []const u8) ![]const i64 {
    for (rs) |r| if (r.needsSecurity()) return error.UnresolvedSecurity;
    var ids: std.ArrayList(i64) = .empty;
    try b.db.exec("BEGIN");
    errdefer b.db.exec("ROLLBACK") catch {};
    for (rs) |r| {
        if (r.duplicate_of != null) continue;
        try ids.append(b.a, try bookings.entry(b, broker, r.entry(), null));
        if (r.security_id) |sid| if (r.security.len > 0) try securities.fillName(b.db, sid, r.security);
    }
    try b.db.exec("COMMIT");
    return ids.items;
}

pub const Upload = struct {
    metadata: paperless.DocumentMetadata,
    dv_tag: i64,
    /// Workflow tags Paperless may add on consumption.
    remove_tags: []const i64,
};

/// Metadata defaults from the parser result; null without a 'dv' tag.
pub fn uploadPlan(
    a: Allocator,
    result: parsers.Result,
    title: []const u8,
    correspondents: []const paperless.Named,
    doc_types: []const paperless.Named,
    tags: []const paperless.Named,
) !?Upload {
    var dv_tag: ?i64 = null;
    var remove: std.ArrayList(i64) = .empty;
    for (tags) |t| {
        if (std.mem.eql(u8, t.name, "dv")) {
            dv_tag = t.id;
        } else if (std.mem.eql(u8, t.name, "todo") or std.mem.eql(u8, t.name, "inbox")) try remove.append(a, t.id);
    }
    const dv = dv_tag orelse return null;
    return .{
        .metadata = .{
            .title = title,
            .created = if (result.created) |d| try d.iso(a) else "",
            .correspondent_id = byNameContains(correspondents, result.correspondent),
            .document_type_id = byName(doc_types, result.document_type),
            .tag_ids = try a.dupe(i64, &.{dv}),
        },
        .dv_tag = dv,
        .remove_tags = remove.items,
    };
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

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn testBook(a: Allocator) !bookings.Book {
    const b = try bookings.testBook(a, .{});
    try b.db.exec("INSERT INTO security (isin, name) VALUES ('US0378331005', '')");
    return b;
}

fn sample(a: Allocator) !parsers.Result {
    const d: f.Date = .{ .year = 2024, .month = 4, .day = 3 };
    const txns = try a.dupe(parsers.Txn, &.{
        .{ .kind = .buy, .date = d, .isin = "US0378331005", .security = "Example Inc.", .quantity = 5_123_456, .total = 50000 },
        .{ .kind = .dividend, .date = d, .isin = "IE00B4L5Y983", .security = "World ETF", .total = 1234 },
        .{ .kind = .deposit, .date = d, .total = 150000 },
    });
    return .{ .parser = "test", .title = "", .created = d, .correspondent = "Scalable Capital", .document_type = "Kontoauszug", .txns = txns };
}

test "rows derive unit prices; check resolves by ISIN and leaves unknown ones" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = try testBook(a);
    defer b.db.close();
    const db = b.db;
    var rs = try rows(a, try sample(a));
    try testing.expectEqual(@as(i64, 9759), rs.items[0].unit);

    try check(b, rs.items, "Broker");
    try testing.expectEqual(@as(?i64, 1), rs.items[0].security_id);
    try testing.expect(rs.items[1].needsSecurity());
    try testing.expect(!rs.items[2].needsSecurity());
    try testing.expectError(error.UnresolvedSecurity, commit(b, rs.items, "Broker"));

    try createSecurity(db, &rs.items[1]);
    try check(b, rs.items, "Broker");
    try testing.expectEqualStrings("Example Inc.", try label(db, a, rs.items[0]));
    const ids = try commit(b, rs.items, "Broker");
    try testing.expectEqual(@as(usize, 3), ids.len);
    // The seeded security got the document's name.
    try testing.expectEqualStrings("Example Inc.", (try securities.get(db, a, 1)).?.name);

    // The same document again: everything is a duplicate.
    const again = try rows(a, try sample(a));
    try check(b, again.items, "Broker");
    try testing.expectEqual(@as(usize, 3), duplicates(again.items));
    try testing.expectEqual(@as(usize, 0), (try commit(b, again.items, "Broker")).len);
}

test "edits keep exact totals unless quantity or price change" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rs = try rows(a, try sample(a));
    const r = &rs.items[0];
    r.security_id = 7;
    var e: Edit = .{ .kind = .buy, .date = "2024-04-04", .security = "Example Inc.", .quantity = r.quantity, .unit = r.unit, .cost = 99, .currency = "EUR", .exchange_rate = 1.0 };
    applyEdit(r, "Example Inc.", e);
    try testing.expectEqual(@as(i64, 50000), r.total);
    try testing.expectEqual(@as(?i64, 7), r.security_id);

    e.quantity = 2_000_000;
    e.security = "Other";
    applyEdit(r, "Example Inc.", e);
    try testing.expectEqual(@as(i64, 2 * r.unit), r.total);
    try testing.expect(r.needsSecurity());
    try testing.expect(r.isin == null);
}

test "upload plan: tags, correspondent and type from the parser result" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const named = struct {
        fn n(id: i64, name: []const u8) paperless.Named {
            return .{ .id = id, .name = name };
        }
    }.n;
    const corr = [_]paperless.Named{named(1, "Scalable")};
    const types = [_]paperless.Named{ named(2, "Abrechnung"), named(3, "kontoauszug") };
    const tags = [_]paperless.Named{ named(4, "inbox"), named(5, "dv") };
    const plan = (try uploadPlan(a, try sample(a), "file", &corr, &types, &tags)).?;
    try testing.expectEqual(@as(i64, 5), plan.dv_tag);
    try testing.expectEqualSlices(i64, &.{4}, plan.remove_tags);
    try testing.expectEqual(@as(?i64, 1), plan.metadata.correspondent_id);
    try testing.expectEqual(@as(?i64, 3), plan.metadata.document_type_id);
    try testing.expectEqualStrings("2024-04-03", plan.metadata.created);
    try testing.expect(try uploadPlan(a, try sample(a), "file", &corr, &types, tags[0..1]) == null);
}

test "parse outcomes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pages = try parsers.fixture(a, .{.{.{ 700, .{.{ 70, "Hello" }} }}});
    try testing.expect(try parse(a, pages, null) == .no_parser);
    try testing.expect(try parse(a, pages, "nope") == .unknown_parser);
    const refused = try parse(a, pages, "scalable_trade");
    try testing.expectEqualStrings("scalable_trade", refused.refused.parser);
    try testing.expectEqualStrings("not a Wertpapierabrechnung", refused.refused.reason);
    try testing.expectEqualStrings("scalable_trade, scalable_statement, llm", try parserNames(a));
}
