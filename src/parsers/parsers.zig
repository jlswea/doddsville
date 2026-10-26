//! Deterministic parsers turning extracted broker PDFs into transactions.
//! A parser only reads `pdf.Page`s; it never touches the database.

const std = @import("std");
const Allocator = std.mem.Allocator;

const f = @import("../format.zig");
const pdf = @import("../pdf/pdf.zig");
pub const scalable = @import("scalable.zig");
pub const llm = @import("llm.zig");

pub const Word = pdf.layout.Word;
pub const Line = pdf.layout.Line;
pub const Page = pdf.Page;

/// Quantities are stored in millionths of a share.
pub const micro = 1_000_000;

pub const Kind = enum { buy, sell, dividend, interest, deposit, withdrawal };

pub const Txn = struct {
    kind: Kind,
    date: f.Date,
    isin: ?[]const u8 = null,
    /// As printed; securities are matched by ISIN first.
    security: ?[]const u8 = null,
    /// Millionths of a share; one unit for cash bookings.
    quantity: i64 = micro,
    /// Gross amount in cents (Kurswert, booking amount), positive.
    total: i64,
    /// Cents per share as printed, when the document states it.
    unit_price: ?i64 = null,
    /// Fees and withheld taxes in cents.
    cost: i64 = 0,
    currency: [3]u8 = "EUR".*,
    /// Multiplier from `currency` to EUR.
    exchange_rate: f64 = 1.0,
};

/// A booking the parser recognised but cannot turn into a transaction.
pub const Skipped = struct {
    date: ?f.Date,
    description: []const u8,
    amount: i64,
};

pub const Result = struct {
    parser: []const u8,
    title: []const u8,
    created: ?f.Date,
    correspondent: []const u8,
    document_type: []const u8,
    txns: []const Txn,
    skipped: []const Skipped = &.{},
};

pub const Error = error{ Unrecognized, OutOfMemory };

/// Why a matching parser gave up. Never contains document values, so it is
/// safe to print and to send along with a bug report.
pub const Diag = struct { reason: []const u8 = "" };

pub const Parser = struct {
    name: []const u8,
    matches: *const fn (pages: []const Page) bool,
    parse: *const fn (a: Allocator, pages: []const Page, diag: *Diag) Error!Result,
};

pub const all = [_]Parser{ scalable.trade, scalable.statement };

pub fn byName(name: []const u8) ?Parser {
    for (all) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

pub fn match(pages: []const Page) ?Parser {
    for (all) |p| if (p.matches(pages)) return p;
    return null;
}

pub fn unrecognized(diag: *Diag, reason: []const u8) error{Unrecognized} {
    diag.reason = reason;
    return error.Unrecognized;
}

// ---------------------------------------------------------------- helpers

pub const Hit = struct { page: usize, line: usize, word: usize };

pub fn line(pages: []const Page, h: Hit) Line {
    return pages[h.page].lines[h.line];
}

pub fn word(pages: []const Page, h: Hit) Word {
    return line(pages, h).words[h.word];
}

/// First word equal to `text`, in reading order.
pub fn find(pages: []const Page, text: []const u8) ?Hit {
    for (pages, 0..) |p, pi| for (p.lines, 0..) |l, li| for (l.words, 0..) |w, wi| {
        if (std.mem.eql(u8, w.text, text)) return .{ .page = pi, .line = li, .word = wi };
    };
    return null;
}

/// First line whose leading words equal `prefix`.
pub fn findLine(pages: []const Page, prefix: []const []const u8) ?Hit {
    for (pages, 0..) |p, pi| for (p.lines, 0..) |l, li| {
        if (startsWith(l, prefix)) return .{ .page = pi, .line = li, .word = 0 };
    };
    return null;
}

pub fn startsWith(l: Line, prefix: []const []const u8) bool {
    if (l.words.len < prefix.len) return false;
    for (prefix, l.words[0..prefix.len]) |want, w| if (!std.mem.eql(u8, want, w.text)) return false;
    return true;
}

pub fn next(pages: []const Page, h: Hit) ?Word {
    const ws = line(pages, h).words;
    return if (h.word + 1 < ws.len) ws[h.word + 1] else null;
}

/// German amount "1.234,56", optionally signed, to cents.
pub fn amount(s: []const u8) ?i64 {
    var body = s;
    var sign: i64 = 1;
    if (body.len > 0 and (body[0] == '-' or body[0] == '+')) {
        if (body[0] == '-') sign = -1;
        body = body[1..];
    }
    const comma = std.mem.indexOfScalar(u8, body, ',') orelse return null;
    if (body.len - comma - 1 != 2) return null;
    const euros = digitsWithSeparators(body[0..comma]) orelse return null;
    const cents = std.fmt.parseInt(i64, body[comma + 1 ..], 10) catch return null;
    if (body[comma + 1] == '+' or body[comma + 1] == '-') return null;
    const total = std.math.add(i64, std.math.mul(i64, euros, 100) catch return null, cents) catch return null;
    return sign * total;
}

/// German quantity "12", "0,57" or "1.234,5" to millionths.
pub fn quantity(s: []const u8) ?i64 {
    const comma = std.mem.indexOfScalar(u8, s, ',');
    const whole = digitsWithSeparators(if (comma) |c| s[0..c] else s) orelse return null;
    var frac: i64 = 0;
    if (comma) |c| {
        const digits = s[c + 1 ..];
        if (digits.len == 0 or digits.len > 6) return null;
        for (digits) |ch| if (!std.ascii.isDigit(ch)) return null;
        frac = std.fmt.parseInt(i64, digits, 10) catch return null;
        frac *= std.math.pow(i64, 10, @intCast(6 - digits.len));
    }
    return std.math.add(i64, std.math.mul(i64, whole, micro) catch return null, frac) catch null;
}

/// "1.234" with '.' thousands separators in groups of three.
fn digitsWithSeparators(s: []const u8) ?i64 {
    if (s.len == 0 or s.len > 15) return null;
    var v: i64 = 0;
    var group: usize = 0;
    var seen_dot = false;
    for (s, 0..) |ch, i| {
        if (ch == '.') {
            if (i == 0 or (seen_dot and group != 3) or (!seen_dot and group > 3)) return null;
            seen_dot = true;
            group = 0;
            continue;
        }
        if (!std.ascii.isDigit(ch)) return null;
        v = v * 10 + (ch - '0');
        group += 1;
    }
    if (seen_dot and group != 3) return null;
    return v;
}

pub fn date(s: []const u8) ?f.Date {
    if (s.len != 10) return null;
    return f.parseGermanDate(s) catch null;
}

/// ISO 6166: two letters, nine alphanumerics, Luhn check digit over the
/// letters expanded to two-digit numbers.
pub fn isIsin(s: []const u8) bool {
    if (s.len != 12) return false;
    if (!std.ascii.isUpper(s[0]) or !std.ascii.isUpper(s[1]) or !std.ascii.isDigit(s[11])) return false;
    var digits: [24]u8 = undefined;
    var n: usize = 0;
    for (s[0..11]) |ch| {
        if (std.ascii.isDigit(ch)) {
            digits[n] = ch - '0';
            n += 1;
        } else if (std.ascii.isUpper(ch)) {
            const v = ch - 'A' + 10;
            digits[n] = v / 10;
            digits[n + 1] = v % 10;
            n += 2;
        } else return false;
    }
    var sum: u32 = 0;
    for (0..n) |k| {
        var d: u32 = digits[n - 1 - k];
        if (k % 2 == 0) {
            d *= 2;
            if (d > 9) d -= 9;
        }
        sum += d;
    }
    return (10 - sum % 10) % 10 == s[11] - '0';
}

/// Joins the texts of `words` with single spaces.
pub fn join(a: Allocator, words: []const Word) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (words, 0..) |w, i| {
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, w.text);
    }
    return out.items;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// Builds pages from `.{ y, .{ .{ x, "text" }, ... } }` rows for parser tests.
pub fn fixture(a: Allocator, comptime pages: anytype) ![]Page {
    const out = try a.alloc(Page, pages.len);
    inline for (pages, 0..) |rows, pi| {
        const lines = try a.alloc(Line, rows.len);
        inline for (rows, 0..) |row, li| {
            const ws = try a.alloc(Word, row[1].len);
            inline for (row[1], 0..) |cell, wi| {
                const x: f32 = cell[0];
                ws[wi] = .{ .x0 = x, .x1 = x + 5 * @as(f32, @floatFromInt(cell[1].len)), .y = row[0], .size = 8, .text = cell[1] };
            }
            lines[li] = .{ .y = row[0], .words = ws, .text = try join(a, ws) };
        }
        out[pi] = .{ .lines = lines };
    }
    return out;
}

test "amounts" {
    try testing.expectEqual(@as(?i64, 123456), amount("1.234,56"));
    try testing.expectEqual(@as(?i64, -99), amount("-0,99"));
    try testing.expectEqual(@as(?i64, 1000000), amount("+10.000,00"));
    try testing.expectEqual(@as(?i64, null), amount("1234"));
    try testing.expectEqual(@as(?i64, null), amount("1,5"));
    try testing.expectEqual(@as(?i64, null), amount("12.34,56"));
    try testing.expectEqual(@as(?i64, null), amount("1.2345,67"));
    try testing.expectEqual(@as(?i64, null), amount(".123,45"));
    try testing.expectEqual(@as(?i64, null), amount("1,-5"));
}

test "quantities" {
    try testing.expectEqual(@as(?i64, 12 * micro), quantity("12"));
    try testing.expectEqual(@as(?i64, 570_000), quantity("0,57"));
    try testing.expectEqual(@as(?i64, 1_234_500_000), quantity("1.234,5"));
    try testing.expectEqual(@as(?i64, 1), quantity("0,000001"));
    try testing.expectEqual(@as(?i64, null), quantity("0,0000001"));
    try testing.expectEqual(@as(?i64, null), quantity("1,"));
    try testing.expectEqual(@as(?i64, null), quantity("x"));
}

test "dates and ISINs" {
    try testing.expectEqual(f.Date{ .year = 2024, .month = 2, .day = 29 }, date("29.02.2024").?);
    try testing.expect(date("30.02.2024") == null);
    try testing.expect(date("1.2.2024") == null);
    try testing.expect(isIsin("US0378331005"));
    try testing.expect(isIsin("IE00B4L5Y983"));
    try testing.expect(isIsin("DE0007164600"));
    try testing.expect(!isIsin("US0378331006"));
    try testing.expect(!isIsin("us0378331005"));
    try testing.expect(!isIsin("US037833100"));
}

test "find, findLine and next over a fixture" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pages = try fixture(arena.allocator(), .{.{
        .{ 700, .{ .{ 65, "Kurswert" }, .{ 418, "EUR" }, .{ 499, "1.000,00" } } },
        .{ 680, .{ .{ 65, "Zu" }, .{ 80, "Lasten" }, .{ 418, "EUR" } } },
    }});
    const h = find(pages, "EUR").?;
    try testing.expectEqual(@as(usize, 0), h.line);
    try testing.expectEqualStrings("1.000,00", next(pages, h).?.text);
    try testing.expectEqual(@as(usize, 1), findLine(pages, &.{ "Zu", "Lasten" }).?.line);
    try testing.expect(findLine(pages, &.{ "Zu", "Gunsten" }) == null);
}

test {
    _ = scalable;
    _ = llm;
}
