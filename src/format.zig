//! Port of formatting.py: ANSI colours, money parsing/formatting, dates,
//! and Python-style column padding.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const RESET = "\x1b[0m";
pub const BOLD = "\x1b[1m";
pub const RED = "\x1b[31m";
pub const GREEN = "\x1b[32m";
pub const YELLOW = "\x1b[33m";
pub const BLUE = "\x1b[34m";

pub fn currencySymbol(a: Allocator, currency: []const u8) ![]const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "EUR", "€" }, .{ "USD", "$" }, .{ "GBP", "£" }, .{ "CHF", "CHF " },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], currency)) return m[1];
    return std.fmt.allocPrint(a, "{s} ", .{currency});
}

/// "€12.34" / "€-0.05" (same output as Python's f"{symbol}{cents/100:.2f}").
pub fn cents(a: Allocator, value: i64) ![]const u8 {
    return centsIn(a, value, "EUR");
}

pub fn centsIn(a: Allocator, value: i64, currency: []const u8) ![]const u8 {
    const sym = try currencySymbol(a, currency);
    const neg = value < 0;
    const abs: u64 = @abs(value);
    return std.fmt.allocPrint(a, "{s}{s}{d}.{d:0>2}", .{ sym, if (neg) "-" else "", abs / 100, abs % 100 });
}

/// Green "+€x" for positive, red "-€x" for negative, plain for zero.
pub fn centsColored(a: Allocator, value: i64) ![]const u8 {
    const f = try cents(a, @intCast(@abs(value)));
    if (value > 0) return std.fmt.allocPrint(a, "{s}+{s}{s}", .{ GREEN, f, RESET });
    if (value < 0) return std.fmt.allocPrint(a, "{s}-{s}{s}", .{ RED, f, RESET });
    return f;
}

pub const ParseError = error{InvalidArgument};

/// Port of cents_from_decimal_string: exactly two decimals, no float maths.
/// On error `msg` gets the same text argparse would print.
pub fn parseCents(a: Allocator, value: []const u8, msg: *[]const u8) !i64 {
    const dot = std.mem.indexOfScalar(u8, value, '.') orelse {
        msg.* = try std.fmt.allocPrint(a, "'{s}' must have exactly two decimal places (e.g., '12.34').", .{value});
        return error.InvalidArgument;
    };
    const int_part = value[0..dot];
    const dec_part = value[dot + 1 ..];
    if (dec_part.len != 2 or std.mem.indexOfScalar(u8, dec_part, '.') != null) {
        msg.* = try std.fmt.allocPrint(a, "'{s}' must have exactly two decimal places.", .{value});
        return error.InvalidArgument;
    }
    const joined = try std.mem.concat(a, u8, &.{ int_part, dec_part });
    return std.fmt.parseInt(i64, joined, 10) catch {
        msg.* = try std.fmt.allocPrint(a, "'{s}' contains non-numeric characters that prevent conversion to cents.", .{value});
        return error.InvalidArgument;
    };
}

pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,

    /// ISO format as stored in the database.
    pub fn iso(d: Date, a: Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ d.year, d.month, d.day });
    }
};

/// Port of validate_date_format (strptime "%d.%m.%Y").
pub fn parseGermanDate(value: []const u8) ParseError!Date {
    var it = std.mem.splitScalar(u8, value, '.');
    const d = it.next() orelse return error.InvalidArgument;
    const m = it.next() orelse return error.InvalidArgument;
    const y = it.next() orelse return error.InvalidArgument;
    if (it.next() != null) return error.InvalidArgument;
    if (d.len < 1 or d.len > 2 or m.len < 1 or m.len > 2 or y.len != 4) return error.InvalidArgument;
    for ([_][]const u8{ d, m, y }) |part| for (part) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidArgument;
    const date: Date = .{
        .year = std.fmt.parseInt(u16, y, 10) catch return error.InvalidArgument,
        .month = std.fmt.parseInt(u8, m, 10) catch return error.InvalidArgument,
        .day = std.fmt.parseInt(u8, d, 10) catch return error.InvalidArgument,
    };
    if (date.year < 1 or date.month < 1 or date.month > 12 or date.day < 1) return error.InvalidArgument;
    if (date.day > daysInMonth(date.year, date.month)) return error.InvalidArgument;
    return date;
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        2 => if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// Number of characters (Unicode code points) — what Python's padding counts.
pub fn displayLen(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// Python f"{s:<w}"
pub fn left(a: Allocator, s: []const u8, w: usize) ![]const u8 {
    const n = displayLen(s);
    if (n >= w) return s;
    const out = try a.alloc(u8, s.len + (w - n));
    @memcpy(out[0..s.len], s);
    @memset(out[s.len..], ' ');
    return out;
}

/// Python f"{s:>w}"
pub fn right(a: Allocator, s: []const u8, w: usize) ![]const u8 {
    const n = displayLen(s);
    if (n >= w) return s;
    const pad = w - n;
    const out = try a.alloc(u8, s.len + pad);
    @memset(out[0..pad], ' ');
    @memcpy(out[pad..], s);
    return out;
}

pub fn int(a: Allocator, v: i64) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}", .{v});
}

/// Python repr() of a float, e.g. 1.0, 1.0856.
pub fn pyFloat(a: Allocator, v: f64) ![]const u8 {
    const s = try std.fmt.allocPrint(a, "{d}", .{v});
    for (s) |ch| if (ch == '.' or ch == 'e' or ch == 'n' or ch == 'i') return s;
    return std.fmt.allocPrint(a, "{s}.0", .{s});
}

/// Python str.strip() for ASCII whitespace.
pub fn strip(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n\x0b\x0c");
}

const testing = std.testing;

test "parseCents mirrors cents_from_decimal_string" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msg: []const u8 = "";
    try testing.expectEqual(@as(i64, 1234), try parseCents(a, "12.34", &msg));
    try testing.expectEqual(@as(i64, 5), try parseCents(a, "0.05", &msg));
    try testing.expectEqual(@as(i64, -1234), try parseCents(a, "-12.34", &msg));
    try testing.expectEqual(@as(i64, -50), try parseCents(a, "-0.50", &msg));
    try testing.expectError(error.InvalidArgument, parseCents(a, "12", &msg));
    try testing.expectEqualStrings("'12' must have exactly two decimal places (e.g., '12.34').", msg);
    try testing.expectError(error.InvalidArgument, parseCents(a, "12.3", &msg));
    try testing.expectError(error.InvalidArgument, parseCents(a, "12.345", &msg));
    try testing.expectError(error.InvalidArgument, parseCents(a, "1.2.34", &msg));
    try testing.expectError(error.InvalidArgument, parseCents(a, "ab.cd", &msg));
}

test "cents formatting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("€12.34", try cents(a, 1234));
    try testing.expectEqualStrings("€0.00", try cents(a, 0));
    try testing.expectEqualStrings("€-0.05", try cents(a, -5));
    try testing.expectEqualStrings("€-12.34", try cents(a, -1234));
    try testing.expectEqualStrings("$1.00", try centsIn(a, 100, "USD"));
    try testing.expectEqualStrings("JPY 1.00", try centsIn(a, 100, "JPY"));
    try testing.expectEqualStrings(GREEN ++ "+€1.00" ++ RESET, try centsColored(a, 100));
    try testing.expectEqualStrings(RED ++ "-€1.00" ++ RESET, try centsColored(a, -100));
    try testing.expectEqualStrings("€0.00", try centsColored(a, 0));
}

test "dates" {
    const d = try parseGermanDate("05.03.2024");
    try testing.expectEqual(@as(u8, 5), d.day);
    _ = try parseGermanDate("1.1.2024");
    _ = try parseGermanDate("29.02.2024");
    try testing.expectError(error.InvalidArgument, parseGermanDate("29.02.2023"));
    try testing.expectError(error.InvalidArgument, parseGermanDate("2024-01-01"));
    try testing.expectError(error.InvalidArgument, parseGermanDate("32.01.2024"));
}

test "padding counts code points" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("€1.00 ", try left(a, "€1.00", 6));
    try testing.expectEqualStrings("  €1.00", try right(a, "€1.00", 7));
    try testing.expectEqualStrings("1.0", try pyFloat(a, 1.0));
    try testing.expectEqualStrings("1.0856", try pyFloat(a, 1.0856));
}

/// Comptime string repetition (`"-" ** n` was removed in Zig 0.17).
pub fn rep(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const S = struct {
        const value: [s.len * n]u8 = blk: {
            var buf: [s.len * n]u8 = undefined;
            for (0..n) |i| @memcpy(buf[i * s.len ..][0..s.len], s);
            break :blk buf;
        };
    };
    return &S.value;
}

test "rep" {
    try testing.expectEqualStrings("---", rep("-", 3));
    try testing.expectEqualStrings("══", rep("═", 2));
}
