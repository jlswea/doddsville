//! ToUnicode CMaps (ISO 32000-1 §9.10.3): character code to Unicode text.

const std = @import("std");
const Allocator = std.mem.Allocator;

const syntax = @import("syntax.zig");

const CMap = @This();

pub const Error = error{BadCMap} || syntax.Error;

/// Upper bound on bfchar/bfrange entries; a font has at most 65536 codes.
pub const max_entries = 65536;

const Char = struct { code: u32, utf8: []const u8 };

const Range = struct {
    lo: u32,
    hi: u32,
    /// UTF-16 code units for `lo`; later codes increment the last unit.
    base: []const u16,
    /// `[<dst> ...]` form: one UTF-8 string per code in lo..hi.
    each: ?[]const []const u8,
};

/// Bytes per character code, from the codespace range.
code_len: u8 = 2,
/// Sorted by code.
chars: []const Char = &.{},
ranges: []const Range = &.{},

pub fn parse(a: Allocator, data: []const u8) Error!CMap {
    var chars: std.ArrayList(Char) = .empty;
    var ranges: std.ArrayList(Range) = .empty;
    var code_len: ?u8 = null;
    var p: syntax.Parser = .init(a, data);
    while (try p.lex.next()) |tok| {
        if (tok != .keyword) continue;
        const kw = tok.keyword;
        if (std.mem.eql(u8, kw, "begincodespacerange")) {
            while (try hexOrEnd(&p, "endcodespacerange")) |lo| {
                _ = (try hexOrEnd(&p, "endcodespacerange")) orelse return error.BadCMap;
                if (lo.len == 0 or lo.len > 2) return error.BadCMap;
                if (code_len) |l| if (l != lo.len) return error.BadCMap;
                code_len = @intCast(lo.len);
            }
        } else if (std.mem.eql(u8, kw, "beginbfchar")) {
            while (try hexOrEnd(&p, "endbfchar")) |src| {
                const dst = (try hexOrEnd(&p, "endbfchar")) orelse return error.BadCMap;
                if (chars.items.len + ranges.items.len == max_entries) return error.BadCMap;
                try chars.append(a, .{ .code = try code(src), .utf8 = try utf16beToUtf8(a, dst) });
            }
        } else if (std.mem.eql(u8, kw, "beginbfrange")) {
            while (try hexOrEnd(&p, "endbfrange")) |lo_s| {
                const hi_s = (try hexOrEnd(&p, "endbfrange")) orelse return error.BadCMap;
                const lo = try code(lo_s);
                const hi = try code(hi_s);
                if (hi < lo) return error.BadCMap;
                if (chars.items.len + ranges.items.len == max_entries) return error.BadCMap;
                const dst = try p.object();
                switch (dst) {
                    .string => |s| try ranges.append(a, .{ .lo = lo, .hi = hi, .base = try units(a, s), .each = null }),
                    .array => |items| {
                        if (items.len != hi - lo + 1) return error.BadCMap;
                        const each = try a.alloc([]const u8, items.len);
                        for (items, each) |it, *e| {
                            if (it != .string) return error.BadCMap;
                            e.* = try utf16beToUtf8(a, it.string);
                        }
                        try ranges.append(a, .{ .lo = lo, .hi = hi, .base = &.{}, .each = each });
                    },
                    else => return error.BadCMap,
                }
            }
        }
    }
    std.mem.sort(Char, chars.items, {}, struct {
        fn lt(_: void, x: Char, y: Char) bool {
            return x.code < y.code;
        }
    }.lt);
    return .{ .code_len = code_len orelse 2, .chars = chars.items, .ranges = ranges.items };
}

/// Next hex string, or null at the section's end keyword.
fn hexOrEnd(p: *syntax.Parser, end: []const u8) Error!?[]const u8 {
    const tok = (try p.lex.next()) orelse return error.BadCMap;
    switch (tok) {
        .hex => |raw| return try syntax.decodeHex(p.a, raw),
        .keyword => |k| return if (std.mem.eql(u8, k, end)) null else error.BadCMap,
        else => return error.BadCMap,
    }
}

fn code(bytes: []const u8) Error!u32 {
    if (bytes.len == 0 or bytes.len > 4) return error.BadCMap;
    var v: u32 = 0;
    for (bytes) |b| v = v << 8 | b;
    return v;
}

fn units(a: Allocator, be: []const u8) Error![]const u16 {
    if (be.len == 0 or be.len % 2 != 0) return error.BadCMap;
    const out = try a.alloc(u16, be.len / 2);
    for (out, 0..) |*u, i| u.* = @as(u16, be[2 * i]) << 8 | be[2 * i + 1];
    return out;
}

fn utf16beToUtf8(a: Allocator, be: []const u8) Error![]const u8 {
    const us = try units(a, be);
    var buf: [64]u8 = undefined;
    return a.dupe(u8, encodeUnits(us, &buf));
}

/// Unpaired surrogates become U+FFFD; output is truncated to `buf`.
fn encodeUnits(us: []const u16, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < us.len) : (i += 1) {
        var cp: u21 = std.unicode.replacement_character;
        const u = us[i];
        if (u < 0xd800 or u > 0xdfff) {
            cp = u;
        } else if (u < 0xdc00 and i + 1 < us.len and us[i + 1] >= 0xdc00 and us[i + 1] <= 0xdfff) {
            cp = @intCast(0x10000 + ((@as(u32, u) - 0xd800) << 10) + (us[i + 1] - 0xdc00));
            i += 1;
        }
        const len = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
        if (n + len > buf.len) break;
        _ = std.unicode.utf8Encode(cp, buf[n..]) catch unreachable;
        n += len;
    }
    return buf[0..n];
}

/// Text for `c`, or null when the map has none. The result may point into `buf`.
pub fn lookup(cm: CMap, c: u32, buf: *[64]u8) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = cm.chars.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const m = cm.chars[mid];
        if (m.code == c) return m.utf8;
        if (m.code < c) lo = mid + 1 else hi = mid;
    }
    for (cm.ranges) |r| {
        if (c < r.lo or c > r.hi) continue;
        if (r.each) |each| return each[c - r.lo];
        var us: [16]u16 = undefined;
        const n = @min(r.base.len, us.len);
        @memcpy(us[0..n], r.base[0..n]);
        const last: u32 = @as(u32, us[n - 1]) + (c - r.lo);
        if (last > 0xffff) return null;
        us[n - 1] = @intCast(last);
        return encodeUnits(us[0..n], buf);
    }
    return null;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const sample =
    \\/CIDInit /ProcSet findresource begin
    \\12 dict begin
    \\begincmap
    \\/CMapName /Adobe-Identity-UCS def
    \\1 begincodespacerange
    \\<0000> <FFFF>
    \\endcodespacerange
    \\3 beginbfchar
    \\<0003> <0020>
    \\<0024> <00C4>
    \\<0010> <D835DC9C>
    \\endbfchar
    \\2 beginbfrange
    \\<0100> <0102> <0041>
    \\<0200> <0201> [<0066006C> <20AC>]
    \\endbfrange
    \\endcmap
    \\CMapName currentdict /CMap defineresource pop
    \\end
    \\end
;

test "bfchar, bfrange and bfrange arrays" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cm = try CMap.parse(arena.allocator(), sample);
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(u8, 2), cm.code_len);
    try testing.expectEqualStrings(" ", cm.lookup(0x0003, &buf).?);
    try testing.expectEqualStrings("Ä", cm.lookup(0x0024, &buf).?);
    try testing.expectEqualStrings("𝒜", cm.lookup(0x0010, &buf).?);
    try testing.expectEqualStrings("A", cm.lookup(0x0100, &buf).?);
    try testing.expectEqualStrings("C", cm.lookup(0x0102, &buf).?);
    try testing.expectEqualStrings("fl", cm.lookup(0x0200, &buf).?);
    try testing.expectEqualStrings("€", cm.lookup(0x0201, &buf).?);
    try testing.expect(cm.lookup(0x0103, &buf) == null);
}

test "an identity range over the whole code space stays a range" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cm = try CMap.parse(arena.allocator(), "1 beginbfrange <0000> <FFFF> <0000> endbfrange");
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), cm.ranges.len);
    try testing.expectEqualStrings("ü", cm.lookup(0x00fc, &buf).?);
    try testing.expectEqualStrings("€", cm.lookup(0x20ac, &buf).?);
}

test "malformed maps are rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.BadCMap, CMap.parse(a, "1 beginbfchar <0001> endbfchar"));
    try testing.expectError(error.BadCMap, CMap.parse(a, "1 beginbfrange <0005> <0001> <0041> endbfrange"));
    try testing.expectError(error.BadCMap, CMap.parse(a, "1 beginbfrange <0001> <0003> [<0041>] endbfrange"));
    try testing.expectError(error.Syntax, CMap.parse(a, "1 beginbfchar <0001> <004"));
}
