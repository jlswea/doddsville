//! Scalable Capital documents.

const std = @import("std");
const Allocator = std.mem.Allocator;

const f = @import("../format.zig");
const p = @import("parsers.zig");

const correspondent = "Scalable Capital";

// ------------------------------------------------- Wertpapierabrechnung

/// Trade confirmation (Wertpapierabrechnung: Kauf/Verkauf) as issued by
/// Baader Bank for Scalable Capital.
pub const trade: p.Parser = .{ .name = "scalable_trade", .matches = tradeMatches, .parse = tradeParse };

fn tradeKind(pages: []const p.Page) ?p.Kind {
    const h = p.find(pages, "Wertpapierabrechnung:") orelse return null;
    if (p.find(pages, "Scalable") == null) return null;
    const w = p.next(pages, h) orelse return null;
    if (std.mem.eql(u8, w.text, "Kauf")) return .buy;
    if (std.mem.eql(u8, w.text, "Verkauf")) return .sell;
    return null;
}

fn tradeMatches(pages: []const p.Page) bool {
    return tradeKind(pages) != null;
}

/// Currency code followed by an amount, at the end of `words`.
fn trailingAmount(words: []const p.Word) ?struct { currency: []const u8, cents: i64 } {
    if (words.len < 2) return null;
    const cents = p.amount(words[words.len - 1].text) orelse return null;
    const cur = words[words.len - 2].text;
    if (cur.len != 3) return null;
    for (cur) |ch| if (!std.ascii.isUpper(ch)) return null;
    return .{ .currency = cur, .cents = cents };
}

fn tradeParse(a: Allocator, pages: []const p.Page, diag: *p.Diag) p.Error!p.Result {
    const kind = tradeKind(pages) orelse return p.unrecognized(diag, "not a Wertpapierabrechnung");

    const isin_hit = p.find(pages, "ISIN:") orelse return p.unrecognized(diag, "missing ISIN");
    const isin = (p.next(pages, isin_hit) orelse return p.unrecognized(diag, "missing ISIN")).text;
    if (!p.isIsin(isin)) return p.unrecognized(diag, "ISIN fails its check digit");

    // Header "Nominale ISIN: … WKN: … Kurs", then "STK <n> <name> <ccy> <price>".
    const header = p.line(pages, isin_hit);
    const kurs_x = for (header.words) |w| {
        if (std.mem.eql(u8, w.text, "Kurs")) break w.x0;
    } else return p.unrecognized(diag, "missing Kurs column");
    const name_x = p.word(pages, isin_hit).x0;
    const lines = pages[isin_hit.page].lines;
    if (isin_hit.line + 1 >= lines.len) return p.unrecognized(diag, "missing position line");
    const pos = lines[isin_hit.line + 1];
    if (!p.startsWith(pos, &.{"STK"}) or pos.words.len < 2) return p.unrecognized(diag, "missing STK line");
    const qty = p.quantity(pos.words[1].text) orelse return p.unrecognized(diag, "unreadable quantity");
    if (qty <= 0) return p.unrecognized(diag, "quantity is not positive");

    var name_words: std.ArrayList(p.Word) = .empty;
    var price_words: std.ArrayList(p.Word) = .empty;
    for (pos.words[2..]) |w| {
        if (w.x0 >= kurs_x - 5) {
            try price_words.append(a, w);
        } else if (w.x0 >= name_x - 5) try name_words.append(a, w);
    }
    // The name may continue on the next line, within the same column.
    if (isin_hit.line + 2 < lines.len) {
        const cont = lines[isin_hit.line + 2];
        const in_column = for (cont.words) |w| {
            if (w.x0 < name_x - 5 or w.x0 >= kurs_x - 5) break false;
        } else true;
        if (in_column and pos.y - cont.y < 2.5 * pos.words[0].size) try name_words.appendSlice(a, cont.words);
    }
    if (name_words.items.len == 0) return p.unrecognized(diag, "missing security name");
    const price = trailingAmount(price_words.items) orelse return p.unrecognized(diag, "missing Kurs");

    const kw_line = p.findLine(pages, &.{"Kurswert"}) orelse return p.unrecognized(diag, "missing Kurswert");
    const kurswert = trailingAmount(p.line(pages, kw_line).words) orelse return p.unrecognized(diag, "unreadable Kurswert");
    const settle_line = p.findLine(pages, &.{ "Zu", if (kind == .buy) "Lasten" else "Gunsten" }) orelse
        return p.unrecognized(diag, "missing Zu Lasten/Gunsten line");
    const settle = trailingAmount(p.line(pages, settle_line).words) orelse return p.unrecognized(diag, "unreadable settlement amount");

    for ([_][]const u8{ price.currency, kurswert.currency, settle.currency }) |c| {
        if (!std.mem.eql(u8, c, "EUR")) return p.unrecognized(diag, "only EUR trades are supported");
    }
    if (price.cents <= 0 or kurswert.cents <= 0) return p.unrecognized(diag, "non-positive Kurs or Kurswert");
    // Kurs × Stück must reproduce the Kurswert to within a cent per share.
    const computed = std.math.mul(i128, price.cents, qty) catch unreachable;
    const diff = @abs(computed - @as(i128, kurswert.cents) * p.micro);
    if (diff > @max(qty, p.micro)) return p.unrecognized(diag, "Kurs × Stück does not match Kurswert");

    const cost = if (kind == .buy) settle.cents - kurswert.cents else kurswert.cents - settle.cents;
    if (cost < 0) return p.unrecognized(diag, "settlement amount implies negative costs");

    const trade_date = tradeDate(pages) orelse return p.unrecognized(diag, "missing trade date");
    const name = try p.join(a, name_words.items);

    const txns = try a.alloc(p.Txn, 1);
    txns[0] = .{
        .kind = kind,
        .date = trade_date,
        .isin = isin,
        .security = name,
        .quantity = qty,
        .total = kurswert.cents,
        .unit_price = price.cents,
        .cost = cost,
    };
    return .{
        .parser = trade.name,
        .title = try std.fmt.allocPrint(a, "Wertpapierabrechnung {s} {s}", .{ if (kind == .buy) "Kauf" else "Verkauf", name }),
        .created = documentDate(pages),
        .correspondent = correspondent,
        .document_type = "Abrechnung",
        .txns = txns,
    };
}

/// Handelsdatum from the execution table, else the Auftragsdatum.
fn tradeDate(pages: []const p.Page) ?f.Date {
    for (pages) |pg| for (pg.lines, 0..) |l, li| {
        if (!p.startsWith(l, &.{ "Nominale", "Kurs" })) continue;
        const datum_x = for (l.words) |w| {
            if (std.mem.eql(u8, w.text, "datum")) break w.x0;
        } else continue;
        if (li + 1 >= pg.lines.len) continue;
        for (pg.lines[li + 1].words) |w| {
            if (@abs(w.x0 - datum_x) < 10) if (p.date(w.text)) |d| return d;
        }
    };
    const h = p.find(pages, "Auftragsdatum:") orelse return null;
    return p.date((p.next(pages, h) orelse return null).text);
}

/// The letter date: the first line on page one that is just a date.
fn documentDate(pages: []const p.Page) ?f.Date {
    if (pages.len == 0) return null;
    for (pages[0].lines) |l| {
        if (l.words.len == 1) if (p.date(l.words[0].text)) |d| return d;
    }
    return null;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// Layout of a real Kauf confirmation with invented values.
fn buyFixture(a: Allocator) ![]p.Page {
    return p.fixture(a, .{.{
        .{ 724, .{ .{ 415, "Seite" }, .{ 433, "1/1" } } },
        .{ 715, .{.{ 415, "München" }} },
        .{ 707, .{.{ 415, "05.03.2024" }} },
        .{ 693, .{ .{ 65, "Scalable" }, .{ 106, "Capital" }, .{ 140, "Vermögensverwaltung.GmbH" } } },
        .{ 518, .{ .{ 65, "Wertpapierabrechnung:" }, .{ 204, "Kauf" }, .{ 415, "Datum" } } },
        .{ 492, .{ .{ 65, "Auftragsdatum:" }, .{ 136, "01.03.2024" }, .{ 205, "Ausführungsplatz:" }, .{ 288, "XETRA" } } },
        .{ 465, .{ .{ 65, "Nominale" }, .{ 205, "ISIN:" }, .{ 231, "US0378331005" }, .{ 315, "WKN:" }, .{ 345, "865985" }, .{ 418, "Kurs" } } },
        .{ 451, .{ .{ 65, "STK" }, .{ 88, "12" }, .{ 206, "Example" }, .{ 259, "Inc." }, .{ 418, "EUR" }, .{ 499, "98,40" } } },
        .{ 437, .{ .{ 206, "Registered" }, .{ 260, "Shs" }, .{ 281, "o.N." } } },
        .{ 360, .{ .{ 65, "Kurswert" }, .{ 418, "EUR" }, .{ 499, "1.180,80" } } },
        .{ 343, .{ .{ 65, "Zu" }, .{ 80, "Lasten" }, .{ 115, "Konto" }, .{ 147, "1234567890" }, .{ 306, "Valuta:" }, .{ 342, "05.03.2024" }, .{ 418, "EUR" }, .{ 499, "1.181,79" } } },
        .{ 299, .{ .{ 418, "Handels-" }, .{ 483, "Handels-" } } },
        .{ 287, .{ .{ 65, "Nominale" }, .{ 170, "Kurs" }, .{ 278, "Ausführungsplatz" }, .{ 418, "datum" }, .{ 483, "zeit" } } },
        .{ 273, .{ .{ 65, "STK" }, .{ 93, "12" }, .{ 170, "EUR" }, .{ 224, "98,40" }, .{ 278, "XETRA" }, .{ 418, "04.03.2024" }, .{ 483, "09:01:02:03" } } },
    }});
}

test "Kauf: quantity, prices, costs, trade date, name over two lines" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pages = try buyFixture(a);
    try testing.expect(trade.matches(pages));
    var diag: p.Diag = .{};
    const r = try trade.parse(a, pages, &diag);
    try testing.expectEqual(@as(usize, 1), r.txns.len);
    const t = r.txns[0];
    try testing.expectEqual(p.Kind.buy, t.kind);
    try testing.expectEqualStrings("US0378331005", t.isin.?);
    try testing.expectEqualStrings("Example Inc. Registered Shs o.N.", t.security.?);
    try testing.expectEqual(@as(i64, 12 * p.micro), t.quantity);
    try testing.expectEqual(@as(?i64, 9840), t.unit_price);
    try testing.expectEqual(@as(i64, 118080), t.total);
    try testing.expectEqual(@as(i64, 99), t.cost);
    try testing.expectEqual(f.Date{ .year = 2024, .month = 3, .day = 4 }, t.date);
    try testing.expectEqual(f.Date{ .year = 2024, .month = 3, .day = 5 }, r.created.?);
    try testing.expectEqualStrings("Wertpapierabrechnung Kauf Example Inc. Registered Shs o.N.", r.title);
}

test "Verkauf: costs are Kurswert minus Zu Gunsten" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pages = try p.fixture(a, .{.{
        .{ 724, .{ .{ 65, "Scalable" }, .{ 106, "Capital" } } },
        .{ 518, .{ .{ 65, "Wertpapierabrechnung:" }, .{ 175, "Verkauf" } } },
        .{ 492, .{ .{ 65, "Auftragsdatum:" }, .{ 136, "02.04.2024" } } },
        .{ 465, .{ .{ 65, "Nominale" }, .{ 205, "ISIN:" }, .{ 230, "IE00B4L5Y983" }, .{ 418, "Kurs" } } },
        .{ 451, .{ .{ 65, "STK" }, .{ 84, "3" }, .{ 206, "World" }, .{ 257, "ETF" }, .{ 418, "EUR" }, .{ 507, "80,00" } } },
        .{ 360, .{ .{ 65, "Kurswert" }, .{ 418, "EUR" }, .{ 502, "240,00" } } },
        .{ 343, .{ .{ 65, "Zu" }, .{ 79, "Gunsten" }, .{ 119, "Konto" }, .{ 418, "EUR" }, .{ 503, "230,00" } } },
    }});
    var diag: p.Diag = .{};
    const t = (try trade.parse(a, pages, &diag)).txns[0];
    try testing.expectEqual(p.Kind.sell, t.kind);
    try testing.expectEqual(@as(i64, 1000), t.cost);
    // No execution table: falls back to the Auftragsdatum.
    try testing.expectEqual(f.Date{ .year = 2024, .month = 4, .day = 2 }, t.date);
    try testing.expectEqualStrings("World ETF", t.security.?);
}

test "inconsistent documents are refused with a reason" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pages = try buyFixture(a);
    var diag: p.Diag = .{};

    // Kurswert no longer equals Kurs × Stück.
    @constCast(&pages[0].lines[9].words[2]).text = "1.280,80";
    try testing.expectError(error.Unrecognized, trade.parse(a, pages, &diag));
    try testing.expectEqualStrings("Kurs × Stück does not match Kurswert", diag.reason);

    @constCast(&pages[0].lines[9].words[2]).text = "1.180,80";
    @constCast(&pages[0].lines[6].words[2]).text = "US0378331006";
    try testing.expectError(error.Unrecognized, trade.parse(a, pages, &diag));
    try testing.expectEqualStrings("ISIN fails its check digit", diag.reason);
}

test "other documents do not match" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pages = try p.fixture(arena.allocator(), .{.{
        .{ 700, .{ .{ 70, "Scalable" }, .{ 94, "Capital" } } },
        .{ 291, .{.{ 70, "Kontoauszug" }} },
    }});
    try testing.expect(!trade.matches(pages));
}
