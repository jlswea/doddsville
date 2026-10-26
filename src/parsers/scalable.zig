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

// ----------------------------------------------------------- Kontoauszug

/// Account statement of the Scalable Capital Bank clearing account: one line
/// per booking, security bookings followed by a "<qty> Stk. <name> (<ISIN>)" line.
pub const statement: p.Parser = .{ .name = "scalable_statement", .matches = statementMatches, .parse = statementParse };

const Columns = struct { page: usize, line: usize, description_x: f32 };

fn statementColumns(pages: []const p.Page) ?Columns {
    if (p.find(pages, "Kontoauszug") == null or p.find(pages, "Scalable") == null) return null;
    const h = p.findLine(pages, &.{ "Buchung", "Wertstellung", "Beschreibung" }) orelse return null;
    return .{ .page = h.page, .line = h.line, .description_x = p.line(pages, h).words[2].x0 };
}

fn statementMatches(pages: []const p.Page) bool {
    return statementColumns(pages) != null;
}

/// "<date> <date> <description…> <±amount> EUR"
fn isBooking(l: p.Line) bool {
    return l.words.len >= 5 and p.date(l.words[0].text) != null and p.date(l.words[1].text) != null and
        std.mem.eql(u8, l.words[l.words.len - 1].text, "EUR") and p.amount(l.words[l.words.len - 2].text) != null;
}

/// "(US0378331005)" as the last word of `l`.
fn trailingIsin(l: p.Line) ?[]const u8 {
    const last = l.words[l.words.len - 1].text;
    if (last.len != 14 or last[0] != '(' or last[13] != ')') return null;
    return if (p.isIsin(last[1..13])) last[1..13] else null;
}

const Balance = struct { d: f.Date, cents: i64 };

fn openingAndClosing(pages: []const p.Page) ?[2]Balance {
    var found: [2]Balance = undefined;
    var n: usize = 0;
    for (pages[0].lines) |l| {
        if (!p.startsWith(l, &.{ "Kontostand", "am" }) or l.words.len != 5) continue;
        if (!std.mem.eql(u8, l.words[4].text, "EUR")) return null;
        if (n == 2) return null;
        found[n] = .{ .d = p.date(l.words[2].text) orelse return null, .cents = p.amount(l.words[3].text) orelse return null };
        n += 1;
    }
    if (n != 2) return null;
    const earlier = dateKey(found[0].d) <= dateKey(found[1].d);
    return if (earlier) found else .{ found[1], found[0] };
}

fn dateKey(d: f.Date) u32 {
    return @as(u32, d.year) * 10000 + @as(u32, d.month) * 100 + d.day;
}

fn statementParse(a: Allocator, pages: []const p.Page, diag: *p.Diag) p.Error!p.Result {
    const cols = statementColumns(pages) orelse return p.unrecognized(diag, "not a Kontoauszug");
    const balances = openingAndClosing(pages) orelse return p.unrecognized(diag, "missing opening/closing Kontostand");

    var txns: std.ArrayList(p.Txn) = .empty;
    var skipped: std.ArrayList(p.Skipped) = .empty;
    var sum: i64 = 0;

    for (pages[cols.page..], cols.page..) |pg, pi| {
        const first = if (pi == cols.page) cols.line + 1 else 0;
        for (pg.lines[first..], first..) |l, li| {
            if (!isBooking(l)) continue;
            const booked = p.date(l.words[0].text).?;
            const cents = p.amount(l.words[l.words.len - 2].text).?;
            // The opening Kontostand is end of day: it already includes that day's bookings.
            if (dateKey(booked) > dateKey(balances[0].d))
                sum = std.math.add(i64, sum, cents) catch return p.unrecognized(diag, "amounts overflow");
            const desc_words = l.words[2 .. l.words.len - 2];
            const desc = try p.join(a, desc_words);
            const cont: ?p.Line = if (li + 1 < pg.lines.len and !isBooking(pg.lines[li + 1]) and
                pg.lines[li + 1].words[0].x0 >= cols.description_x - 5 and
                pg.lines[li + 1].words[0].x0 < cols.description_x + 5) pg.lines[li + 1] else null;

            switch (classify(desc_words, cents, cont)) {
                .buy, .sell => |b| {
                    const c = cont.?;
                    const qty = p.quantity(c.words[0].text).?;
                    if (qty <= 0) return p.unrecognized(diag, "quantity is not positive");
                    try txns.append(a, .{
                        .kind = if (b == .buy) .buy else .sell,
                        .date = booked,
                        .isin = trailingIsin(c).?,
                        .security = try p.join(a, c.words[2 .. c.words.len - 1]),
                        .quantity = qty,
                        .total = @intCast(@abs(cents)),
                    });
                },
                .distribution => {
                    const c = cont.?;
                    try txns.append(a, .{
                        .kind = .dividend,
                        .date = booked,
                        .isin = trailingIsin(c).?,
                        .security = try p.join(a, c.words[0 .. c.words.len - 1]),
                        .total = cents,
                    });
                },
                .deposit => try txns.append(a, .{ .kind = .deposit, .date = booked, .total = cents }),
                .unknown => try skipped.append(a, .{ .date = booked, .description = desc, .amount = cents }),
            }
        }
    }
    if (txns.items.len + skipped.items.len == 0) return p.unrecognized(diag, "no bookings found");
    if (balances[0].cents + sum != balances[1].cents) return p.unrecognized(diag, "bookings do not add up to the change in Kontostand");

    return .{
        .parser = statement.name,
        .title = "Kontoauszug",
        .created = statementDate(pages),
        .correspondent = correspondent,
        .document_type = "Kontoauszug",
        .txns = txns.items,
        .skipped = skipped.items,
    };
}

const Booking = enum { buy, sell, deposit, distribution, unknown };

fn classify(desc: []const p.Word, cents: i64, cont: ?p.Line) Booking {
    const first = desc[0].text;
    const security_line = if (cont) |c| c.words.len >= 4 and std.mem.eql(u8, c.words[1].text, "Stk.") and
        p.quantity(c.words[0].text) != null and trailingIsin(c) != null else false;
    if (std.mem.eql(u8, first, "Kauf") and cents < 0 and security_line) return .buy;
    if (std.mem.eql(u8, first, "Verkauf") and cents > 0 and security_line) return .sell;
    if (desc.len == 1 and cents > 0 and (std.mem.eql(u8, first, "Überweisung") or std.mem.eql(u8, first, "Lastschrift"))) return .deposit;
    if (desc.len == 2 and std.mem.eql(u8, first, "Kapitalmaßnahme") and std.mem.eql(u8, desc[1].text, "Ausschüttungen") and
        cents > 0 and cont != null and cont.?.words.len >= 2 and trailingIsin(cont.?) != null) return .distribution;
    return .unknown;
}

/// "Datum <date>" in the letter head.
fn statementDate(pages: []const p.Page) ?f.Date {
    const h = p.find(pages, "Datum") orelse return null;
    return p.date((p.next(pages, h) orelse return null).text);
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

/// Layout of a real Kontoauszug with invented values.
fn statementFixture(a: Allocator) ![]p.Page {
    return p.fixture(a, .{.{
        .{ 700, .{ .{ 70, "Scalable" }, .{ 94, "Capital" }, .{ 114, "Bank" }, .{ 129, "GmbH" } } },
        .{ 640, .{ .{ 440, "Datum" }, .{ 481, "02.05.2024" } } },
        .{ 539, .{.{ 70, "Kontoauszug" }} },
        .{ 526, .{ .{ 70, "Zeitraum" }, .{ 103, "01.04.2024" }, .{ 145, "-" }, .{ 150, "30.04.2024" } } },
        .{ 469, .{ .{ 70, "Kontostand" }, .{ 113, "am" }, .{ 125, "01.04.2024" }, .{ 181, "100,00" }, .{ 216, "EUR" } } },
        .{ 458, .{ .{ 70, "Kontostand" }, .{ 113, "am" }, .{ 125, "30.04.2024" }, .{ 181, "1.123,45" }, .{ 199, "EUR" } } },
        .{ 413, .{ .{ 71, "Buchung" }, .{ 123, "Wertstellung" }, .{ 182, "Beschreibung" }, .{ 499, "Betrag" } } },
        .{ 382, .{ .{ 71, "02.04.2024" }, .{ 123, "02.04.2024" }, .{ 182, "Überweisung" }, .{ 469, "+1.500,00" }, .{ 508, "EUR" } } },
        .{ 356, .{ .{ 71, "03.04.2024" }, .{ 123, "05.04.2024" }, .{ 182, "Kauf" }, .{ 201, "durch" }, .{ 222, "Sparplanausführung" }, .{ 471, "-500,00" }, .{ 508, "EUR" } } },
        .{ 339, .{ .{ 182, "5,123456" }, .{ 207, "Stk." }, .{ 223, "World" }, .{ 254, "ETF" }, .{ 346, "(Acc)" }, .{ 366, "(IE00B4L5Y983)" } } },
        .{ 312, .{ .{ 71, "15.04.2024" }, .{ 123, "15.04.2024" }, .{ 182, "Kapitalmaßnahme" }, .{ 249, "Ausschüttungen" }, .{ 477, "+12,34" }, .{ 508, "EUR" } } },
        .{ 295, .{ .{ 182, "Example" }, .{ 211, "Inc." }, .{ 252, "(US0378331005)" } } },
        .{ 268, .{ .{ 71, "16.04.2024" }, .{ 123, "16.04.2024" }, .{ 182, "Auf" }, .{ 194, "Erträge" }, .{ 246, "erstattete" }, .{ 350, "Kapitalertragssteuer" }, .{ 480, "+11,11" }, .{ 508, "EUR" } } },
    }});
}

test "Kontoauszug: buys with fractions, deposits, distributions, skipped refunds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pages = try statementFixture(a);
    try testing.expect(statement.matches(pages));
    try testing.expect(!trade.matches(pages));
    var diag: p.Diag = .{};
    const r = try statement.parse(a, pages, &diag);
    try testing.expectEqual(@as(usize, 3), r.txns.len);

    try testing.expectEqual(p.Kind.deposit, r.txns[0].kind);
    try testing.expectEqual(@as(i64, 150000), r.txns[0].total);

    const buy = r.txns[1];
    try testing.expectEqual(p.Kind.buy, buy.kind);
    try testing.expectEqual(@as(i64, 5_123_456), buy.quantity);
    try testing.expectEqual(@as(i64, 50000), buy.total);
    try testing.expectEqualStrings("IE00B4L5Y983", buy.isin.?);
    try testing.expectEqualStrings("World ETF (Acc)", buy.security.?);
    try testing.expectEqual(f.Date{ .year = 2024, .month = 4, .day = 3 }, buy.date);

    try testing.expectEqual(p.Kind.dividend, r.txns[2].kind);
    try testing.expectEqualStrings("US0378331005", r.txns[2].isin.?);
    try testing.expectEqualStrings("Example Inc.", r.txns[2].security.?);

    try testing.expectEqual(@as(usize, 1), r.skipped.len);
    try testing.expectEqual(@as(i64, 1111), r.skipped[0].amount);
    try testing.expectEqual(f.Date{ .year = 2024, .month = 5, .day = 2 }, r.created.?);
}

test "Kontoauszug: bookings must add up to the balance change" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pages = try statementFixture(a);
    @constCast(&pages[0].lines[5].words[3]).text = "1.123,46";
    var diag: p.Diag = .{};
    try testing.expectError(error.Unrecognized, statement.parse(a, pages, &diag));
    try testing.expectEqualStrings("bookings do not add up to the change in Kontostand", diag.reason);
}

test "Kontoauszug: bookings on the opening day are already in the opening balance" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pages = try statementFixture(a);
    // Move the 1.500,00 deposit onto the opening day and leave the closing balance alone:
    // the opening balance now has to include it.
    @constCast(&pages[0].lines[7].words[0]).text = "01.04.2024";
    @constCast(&pages[0].lines[4].words[3]).text = "1.600,00";
    var diag: p.Diag = .{};
    const r = try statement.parse(a, pages, &diag);
    try testing.expectEqual(@as(usize, 3), r.txns.len);
}
