//! What text extraction needs from a font (ISO 32000-1 §9.6–9.7): how bytes
//! split into character codes, each code's advance width, and its text.

const std = @import("std");
const Allocator = std.mem.Allocator;

const CMap = @import("CMap.zig");
const Document = @import("Document.zig");
const syntax = @import("syntax.zig");

const Font = @This();

pub const Error = error{UnsupportedFont} || Document.Error || CMap.Error;

/// Glyph widths in thousandths of text space units.
const WidthRange = struct { first: u32, last: u32, width: f32 };

code_len: u8,
to_unicode: ?CMap,
widths: []const WidthRange,
default_width: f32,

pub fn load(doc: *Document, dict: syntax.Dict) Error!Font {
    const to_unicode: ?CMap = if (try doc.get(dict, "ToUnicode")) |tu| switch (tu) {
        .stream => |s| try CMap.parse(doc.a, try doc.decodeStream(s)),
        else => null,
    } else null;

    if (dict.hasName("Subtype", "Type0")) {
        // Identity-H/V: two-byte codes equal to CIDs. Other CMaps are not needed yet.
        const enc = (try doc.get(dict, "Encoding")) orelse return error.UnsupportedFont;
        if (!enc.isName("Identity-H") and !enc.isName("Identity-V")) return error.UnsupportedFont;
        const desc_arr = (try doc.get(dict, "DescendantFonts")) orelse return error.UnsupportedFont;
        if (desc_arr != .array or desc_arr.array.len != 1) return error.UnsupportedFont;
        const desc = try doc.resolve(desc_arr.array[0]);
        if (desc != .dict) return error.UnsupportedFont;
        const dw = if (try doc.get(desc.dict, "DW")) |v| v.number() orelse 1000 else 1000;
        const w = if (try doc.get(desc.dict, "W")) |v| (if (v == .array) v.array else return error.UnsupportedFont) else &.{};
        return .{ .code_len = 2, .to_unicode = to_unicode, .widths = try cidWidths(doc, w), .default_width = @floatCast(dw) };
    }

    const first = if (try doc.get(dict, "FirstChar")) |v| (if (v == .integer and v.integer >= 0 and v.integer <= 255) v.integer else return error.UnsupportedFont) else 0;
    var widths: std.ArrayList(WidthRange) = .empty;
    if (try doc.get(dict, "Widths")) |v| {
        if (v != .array) return error.UnsupportedFont;
        for (v.array, 0..) |wo, i| {
            const wv = (try doc.resolve(wo)).number() orelse return error.UnsupportedFont;
            const c: u32 = @intCast(first + @as(i64, @intCast(i)));
            try widths.append(doc.a, .{ .first = c, .last = c, .width = @floatCast(wv) });
        }
    }
    return .{ .code_len = 1, .to_unicode = to_unicode, .widths = widths.items, .default_width = 0 };
}

/// `[c [w1 w2 ...]]` and `[c_first c_last w]` (ISO 32000-1 §9.7.4.3).
fn cidWidths(doc: *Document, w: []const syntax.Object) Error![]const WidthRange {
    var out: std.ArrayList(WidthRange) = .empty;
    var i: usize = 0;
    while (i < w.len) {
        const first = try cid(try doc.resolve(w[i]));
        if (i + 1 >= w.len) return error.UnsupportedFont;
        const next = try doc.resolve(w[i + 1]);
        if (next == .array) {
            for (next.array, 0..) |wo, k| {
                const wv = (try doc.resolve(wo)).number() orelse return error.UnsupportedFont;
                const c = first + @as(u32, @intCast(k));
                try out.append(doc.a, .{ .first = c, .last = c, .width = @floatCast(wv) });
            }
            i += 2;
        } else {
            if (i + 2 >= w.len) return error.UnsupportedFont;
            const last = try cid(next);
            const wv = (try doc.resolve(w[i + 2])).number() orelse return error.UnsupportedFont;
            if (last < first) return error.UnsupportedFont;
            try out.append(doc.a, .{ .first = first, .last = last, .width = @floatCast(wv) });
            i += 3;
        }
    }
    return out.items;
}

fn cid(o: syntax.Object) Error!u32 {
    if (o != .integer or o.integer < 0 or o.integer > 0xffff) return error.UnsupportedFont;
    return @intCast(o.integer);
}

pub fn width(f: Font, code: u32) f32 {
    for (f.widths) |r| if (code >= r.first and code <= r.last) return r.width;
    return f.default_width;
}

/// Splits a shown string into character codes.
pub const Codes = struct {
    bytes: []const u8,
    len: u8,
    i: usize = 0,

    pub fn next(it: *Codes) ?u32 {
        if (it.i + it.len > it.bytes.len) return null;
        var c: u32 = 0;
        for (it.bytes[it.i..][0..it.len]) |b| c = c << 8 | b;
        it.i += it.len;
        return c;
    }
};

pub fn codes(f: Font, bytes: []const u8) Codes {
    return .{ .bytes = bytes, .len = f.code_len };
}

/// Without a ToUnicode map, single-byte ASCII is taken as is; anything else is
/// unknown (U+FFFD) because the font's encoding tables are not implemented.
pub fn text(f: Font, code: u32, buf: *[64]u8) []const u8 {
    if (f.to_unicode) |cm| if (cm.lookup(code, buf)) |s| return s;
    if (f.code_len == 1 and code >= 0x20 and code < 0x7f) {
        buf[0] = @intCast(code);
        return buf[0..1];
    }
    return "\u{FFFD}";
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn docWith(a: Allocator, objects: []const []const u8) !Document {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "%PDF-1.4\n");
    const offsets = try a.alloc(usize, objects.len);
    for (objects, 0..) |body, i| {
        offsets[i] = out.items.len;
        try out.print(a, "{d} 0 obj\n{s}\nendobj\n", .{ i + 1, body });
    }
    const xref = out.items.len;
    try out.print(a, "xref\n0 {d}\n0000000000 65535 f \n", .{objects.len + 1});
    for (offsets) |off| try out.print(a, "{d:0>10} 00000 n \n", .{off});
    try out.print(a, "trailer\n<< /Size {d} >>\nstartxref\n{d}\n%%EOF\n", .{ objects.len + 1, xref });
    return Document.open(a, out.items, 4096);
}

test "Type0 Identity-H: two-byte codes, W widths, ToUnicode" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cmap = "1 beginbfchar <0024> <0041> endbfchar";
    var doc = try docWith(a, &.{
        "<< /Type /Font /Subtype /Type0 /Encoding /Identity-H /DescendantFonts [2 0 R] /ToUnicode 3 0 R >>",
        "<< /Type /Font /Subtype /CIDFontType2 /DW 500 /W [3 [278] 36 40 667] >>",
        std.fmt.comptimePrint("<< /Length {d} >>\nstream\n{s}\nendstream", .{ cmap.len, cmap }),
    });
    const font = try Font.load(&doc, (try doc.object(.{ .num = 1, .gen = 0 })).dict);
    try testing.expectEqual(@as(f32, 278), font.width(3));
    try testing.expectEqual(@as(f32, 667), font.width(38));
    try testing.expectEqual(@as(f32, 500), font.width(99));

    var it = font.codes("\x00\x24\x00\x03\x01");
    try testing.expectEqual(@as(u32, 0x24), it.next().?);
    try testing.expectEqual(@as(u32, 0x03), it.next().?);
    try testing.expect(it.next() == null);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("A", font.text(0x24, &buf));
    try testing.expectEqualStrings("\u{FFFD}", font.text(0x25, &buf));
}

test "simple font: FirstChar/Widths, ASCII fallback" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try docWith(a, &.{"<< /Type /Font /Subtype /TrueType /FirstChar 32 /Widths [250 333] >>"});
    const font = try Font.load(&doc, (try doc.object(.{ .num = 1, .gen = 0 })).dict);
    try testing.expectEqual(@as(f32, 333), font.width('!'));
    try testing.expectEqual(@as(f32, 0), font.width('A'));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("A", font.text('A', &buf));
    try testing.expectEqualStrings("\u{FFFD}", font.text(0xe4, &buf));
}

test "other Type0 encodings are unsupported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try docWith(a, &.{"<< /Type /Font /Subtype /Type0 /Encoding /UniJIS-UCS2-H /DescendantFonts [] >>"});
    try testing.expectError(error.UnsupportedFont, Font.load(&doc, (try doc.object(.{ .num = 1, .gen = 0 })).dict));
}
