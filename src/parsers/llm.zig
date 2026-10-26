//! Last-resort parsing by a local LLM: the prompt and strict validation of
//! its answer. The HTTP call lives in ollama.zig; this file does no I/O.

const std = @import("std");
const Allocator = std.mem.Allocator;

const f = @import("../format.zig");
const p = @import("parsers.zig");

pub const name = "llm";

/// Port of IMPORT_PROMPT_TEMPLATE in parsers/llm.py.
const prompt_head =
    \\You are a financial document parser. Extract all financial transactions and document metadata from the provided bank/broker statement.
    \\
    \\Output ONLY a valid JSON object with this structure:
    \\{
    \\  "transactions": [{
    \\    "type": "dividend",
    \\    "date": "2025-03-17",
    \\    "security": "Example Corp",
    \\    "isin": "US0000000000",
    \\    "unit_price_cents": 20,
    \\    "quantity": 62,
    \\    "currency": "USD",
    \\    "total_eur_cents": 1134,
    \\    "fees": {"kapitalertragsteuer": 114, "solidaritaetszuschlag": 7, "quellensteuer": 170}
    \\  }],
    \\  "metadata": {"date": "2025-03-17", "issuer": "Scalable Capital"}
    \\}
    \\
    \\Transaction fields:
    \\- "type": one of "buy", "sell", "dividend", "interest", "deposit", "withdrawal"
    \\- "date": date in "YYYY-MM-DD" format
    \\- "unit_price_cents": price per unit in cents of the ORIGINAL currency as positive integer (e.g., 15050 for 150.50)
    \\- "quantity": number of units as integer (buy/sell: shares; dividend: shares held; deposit/withdrawal/interest: 1)
    \\- "currency": ISO currency code of unit_price_cents, as stated in the document for the unit price
    \\- "security": security/company name (required for buy, sell, dividend); "isin" if the document shows one
    \\- "total_eur_cents": gross amount in EUR cents BEFORE taxes/fees. Required when currency is not EUR
    \\- "fees": individual tax/fee line items in EUR cents (positive integers), only items found in the document
    \\
    \\Metadata fields:
    \\- "date": document/statement date in YYYY-MM-DD format
    \\- "issuer": name of the bank or broker that issued this document
    \\
    \\Rules:
    \\1. Convert ALL amounts to positive cents (multiply by 100, remove decimals)
    \\2. Convert German dates (DD.MM.YYYY) to YYYY-MM-DD format
    \\3. Look for keywords: Kauf/Buy, Verkauf/Sell, Dividende/Dividend, Zinsen/Interest, Einzahlung/Deposit, Auszahlung/Withdrawal
    \\4. For dividends unit_price_cents is the dividend per share; for deposits/withdrawals/interest it is the amount with quantity 1
    \\5. Skip header rows, totals, balance summaries, and non-transaction lines
    \\6. Output ONLY the JSON object, no explanation, no markdown code blocks
    \\
    \\Document text:
    \\---
    \\
;
const prompt_tail =
    \\---
    \\
    \\JSON object with transactions and metadata:
;

pub fn prompt(a: Allocator, pages: []const p.Page) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, prompt_head);
    for (pages, 1..) |page, i| {
        try out.print(a, "--- Page {d} ---\n", .{i});
        for (page.lines) |l| {
            try out.appendSlice(a, l.text);
            try out.append(a, '\n');
        }
    }
    try out.appendSlice(a, prompt_tail);
    return out.items;
}

const Answer = struct {
    transactions: []const struct {
        type: []const u8 = "",
        date: []const u8 = "",
        security: ?[]const u8 = null,
        isin: ?[]const u8 = null,
        unit_price_cents: i64 = 0,
        quantity: i64 = 0,
        currency: []const u8 = "EUR",
        total_eur_cents: ?i64 = null,
        fees: ?std.json.ArrayHashMap(i64) = null,
    } = &.{},
    metadata: struct {
        date: ?[]const u8 = null,
        issuer: ?[]const u8 = null,
    } = .{},
};

/// The model's answer, after stripping markdown fences and prose around the
/// JSON object. Transactions failing validation are dropped and counted.
pub fn parseAnswer(a: Allocator, response: []const u8, rejected: *usize, diag: *p.Diag) p.Error!p.Result {
    const start = std.mem.indexOfScalar(u8, response, '{') orelse return p.unrecognized(diag, "no JSON object in the LLM response");
    const end = std.mem.lastIndexOfScalar(u8, response, '}') orelse return p.unrecognized(diag, "no JSON object in the LLM response");
    if (end < start) return p.unrecognized(diag, "no JSON object in the LLM response");
    const answer = std.json.parseFromSliceLeaky(Answer, a, response[start .. end + 1], .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return p.unrecognized(diag, "the LLM response is not the expected JSON");

    var txns: std.ArrayList(p.Txn) = .empty;
    rejected.* = 0;
    for (answer.transactions) |t| {
        const kind = std.meta.stringToEnum(p.Kind, t.type) orelse {
            rejected.* += 1;
            continue;
        };
        const d = isoDate(t.date) orelse {
            rejected.* += 1;
            continue;
        };
        const stock = kind == .buy or kind == .sell or kind == .dividend;
        const security = if (t.security) |s| (if (f.strip(s).len > 0) f.strip(s) else null) else null;
        if (t.unit_price_cents <= 0 or t.quantity <= 0 or t.quantity > 1_000_000_000 or (stock and security == null) or
            t.currency.len != 3)
        {
            rejected.* += 1;
            continue;
        }
        const total = std.math.mul(i64, t.unit_price_cents, t.quantity) catch {
            rejected.* += 1;
            continue;
        };
        var cost: i64 = 0;
        if (t.fees) |fees| for (fees.map.values()) |v| {
            if (v > 0) cost +|= v;
        };
        var currency: [3]u8 = undefined;
        for (&currency, t.currency) |*c, ch| c.* = std.ascii.toUpper(ch);
        // Derived from the two totals rather than asking the model to invert a quoted rate.
        const rate: f64 = if (std.mem.eql(u8, &currency, "EUR")) 1.0 else if (t.total_eur_cents) |eur|
            (if (eur > 0) @as(f64, @floatFromInt(eur)) / @as(f64, @floatFromInt(total)) else 1.0)
        else
            1.0;
        try txns.append(a, .{
            .kind = kind,
            .date = d,
            .isin = if (t.isin) |i| (if (p.isIsin(i)) i else null) else null,
            .security = security,
            // Dividends and cash bookings are stored as a single amount.
            .quantity = if (kind == .buy or kind == .sell) t.quantity * p.micro else p.micro,
            .total = total,
            .unit_price = if (kind == .buy or kind == .sell) t.unit_price_cents else null,
            .cost = cost,
            .currency = currency,
            .exchange_rate = rate,
        });
    }
    return .{
        .parser = name,
        .title = "",
        .created = if (answer.metadata.date) |s| isoDate(s) else null,
        .correspondent = answer.metadata.issuer orelse "",
        .document_type = "Abrechnung",
        .txns = txns.items,
    };
}

fn isoDate(s: []const u8) ?f.Date {
    if (s.len != 10 or s[4] != '-' or s[7] != '-') return null;
    var german: [10]u8 = undefined;
    @memcpy(german[0..2], s[8..10]);
    german[2] = '.';
    @memcpy(german[3..5], s[5..7]);
    german[5] = '.';
    @memcpy(german[6..10], s[0..4]);
    return p.date(&german);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test "answers are validated and converted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const response =
        \\```json
        \\{"transactions": [
        \\  {"type": "dividend", "date": "2025-03-17", "security": "Example Corp", "unit_price_cents": 20, "quantity": 62,
        \\   "currency": "usd", "total_eur_cents": 1134, "fees": {"kapitalertragsteuer": 114, "solidaritaetszuschlag": 7}},
        \\  {"type": "buy", "date": "2025-03-18", "security": "World ETF", "isin": "IE00B4L5Y983", "unit_price_cents": 9840, "quantity": 2},
        \\  {"type": "buy", "date": "18.03.2025", "security": "Bad date", "unit_price_cents": 1, "quantity": 1},
        \\  {"type": "sell", "date": "2025-03-18", "unit_price_cents": 1, "quantity": 1},
        \\  {"type": "gift", "date": "2025-03-18", "unit_price_cents": 1, "quantity": 1}
        \\],
        \\"metadata": {"date": "2025-03-19", "issuer": "Scalable Capital"}}
        \\```
    ;
    var rejected: usize = 0;
    var diag: p.Diag = .{};
    const r = try parseAnswer(a, response, &rejected, &diag);
    try testing.expectEqual(@as(usize, 3), rejected);
    try testing.expectEqual(@as(usize, 2), r.txns.len);

    const div = r.txns[0];
    try testing.expectEqual(p.Kind.dividend, div.kind);
    try testing.expectEqual(@as(i64, 1240), div.total);
    try testing.expectEqual(@as(i64, 121), div.cost);
    try testing.expectEqualStrings("USD", &div.currency);
    try testing.expectApproxEqAbs(@as(f64, 1134.0 / 1240.0), div.exchange_rate, 1e-9);

    const buy = r.txns[1];
    try testing.expectEqual(@as(i64, 2 * p.micro), buy.quantity);
    try testing.expectEqual(@as(?i64, 9840), buy.unit_price);
    try testing.expectEqualStrings("IE00B4L5Y983", buy.isin.?);
    try testing.expectEqualStrings("Scalable Capital", r.correspondent);
    try testing.expectEqual(f.Date{ .year = 2025, .month = 3, .day = 19 }, r.created.?);
}

test "garbage is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var rejected: usize = 0;
    var diag: p.Diag = .{};
    try testing.expectError(error.Unrecognized, parseAnswer(arena.allocator(), "I cannot help with that.", &rejected, &diag));
    try testing.expectError(error.Unrecognized, parseAnswer(arena.allocator(), "{\"transactions\": 3}", &rejected, &diag));
}

test "the prompt carries the page text" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pages = try p.fixture(arena.allocator(), .{.{.{ 700, .{ .{ 70, "Dividende" }, .{ 120, "12,34" } } }}});
    const text = try prompt(arena.allocator(), pages);
    try testing.expect(std.mem.indexOf(u8, text, "--- Page 1 ---\nDividende 12,34\n") != null);
}
