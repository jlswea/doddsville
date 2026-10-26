//! Runs a page's content stream far enough to place every shown glyph
//! (ISO 32000-1 §9.2–9.4). Paths, colours and images are skipped.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Document = @import("Document.zig");
const Font = @import("Font.zig");
const syntax = @import("syntax.zig");

pub const Error = error{BadContent} || Font.Error;

/// Bounds q/Q nesting and operand counts on untrusted input.
const max_saved_states = 32;
const max_operands = 16;

pub const Glyph = struct {
    /// Baseline origin in page space, y up.
    x: f32,
    y: f32,
    /// Advance in page space.
    width: f32,
    /// Effective font size in page space.
    size: f32,
    text_len: u8,
    text_buf: [16]u8,

    pub fn text(g: *const Glyph) []const u8 {
        return g.text_buf[0..g.text_len];
    }
};

/// a b c d e f, row-vector convention as in the spec.
const Matrix = [6]f32;
const identity: Matrix = .{ 1, 0, 0, 1, 0, 0 };

fn mul(m: Matrix, n: Matrix) Matrix {
    return .{
        m[0] * n[0] + m[1] * n[2],
        m[0] * n[1] + m[1] * n[3],
        m[2] * n[0] + m[3] * n[2],
        m[2] * n[1] + m[3] * n[3],
        m[4] * n[0] + m[5] * n[2] + n[4],
        m[4] * n[1] + m[5] * n[3] + n[5],
    };
}

fn translate(tx: f32, ty: f32) Matrix {
    return .{ 1, 0, 0, 1, tx, ty };
}

const State = struct {
    ctm: Matrix = identity,
    font: ?*const Font = null,
    size: f32 = 0,
    char_spacing: f32 = 0,
    word_spacing: f32 = 0,
    /// Tz / 100
    scale: f32 = 1,
    leading: f32 = 0,
    rise: f32 = 0,
};

const FontEntry = struct { name: []const u8, font: Font };

const Interpreter = struct {
    doc: *Document,
    resources: syntax.Dict,
    glyphs: *std.ArrayList(Glyph),
    fonts: std.ArrayList(FontEntry) = .empty,
    state: State = .{},
    saved: [max_saved_states]State = undefined,
    saved_len: usize = 0,
    tm: Matrix = identity,
    tlm: Matrix = identity,
    operands: [max_operands]syntax.Object = undefined,
    operands_len: usize = 0,

    fn run(it: *Interpreter, content: []const u8) Error!void {
        var p: syntax.Parser = .init(it.doc.a, content);
        while (try p.lex.next()) |tok| {
            if (tok != .keyword or std.mem.eql(u8, tok.keyword, "true") or
                std.mem.eql(u8, tok.keyword, "false") or std.mem.eql(u8, tok.keyword, "null"))
            {
                const o = try p.fromToken(tok, 0);
                if (it.operands_len == max_operands) return error.BadContent;
                it.operands[it.operands_len] = o;
                it.operands_len += 1;
                continue;
            }
            const op = tok.keyword;
            if (std.mem.eql(u8, op, "BI")) try skipInlineImage(&p.lex);
            try it.operator(op);
            it.operands_len = 0;
        }
    }

    fn num(it: *const Interpreter, i: usize) Error!f32 {
        if (i >= it.operands_len) return error.BadContent;
        const v = it.operands[i].number() orelse return error.BadContent;
        return @floatCast(v);
    }

    fn need(it: *const Interpreter, n: usize) Error!void {
        if (it.operands_len != n) return error.BadContent;
    }

    fn operator(it: *Interpreter, op: []const u8) Error!void {
        const eql = std.mem.eql;
        const s = &it.state;
        if (eql(u8, op, "q")) {
            if (it.saved_len == max_saved_states) return error.BadContent;
            it.saved[it.saved_len] = s.*;
            it.saved_len += 1;
        } else if (eql(u8, op, "Q")) {
            // Unbalanced Q is common enough in the wild to tolerate.
            if (it.saved_len == 0) return;
            it.saved_len -= 1;
            s.* = it.saved[it.saved_len];
        } else if (eql(u8, op, "cm")) {
            try it.need(6);
            s.ctm = mul(.{ try it.num(0), try it.num(1), try it.num(2), try it.num(3), try it.num(4), try it.num(5) }, s.ctm);
        } else if (eql(u8, op, "BT")) {
            it.tm = identity;
            it.tlm = identity;
        } else if (eql(u8, op, "Tf")) {
            try it.need(2);
            if (it.operands[0] != .name) return error.BadContent;
            s.font = try it.font(it.operands[0].name);
            s.size = try it.num(1);
        } else if (eql(u8, op, "Tc")) {
            try it.need(1);
            s.char_spacing = try it.num(0);
        } else if (eql(u8, op, "Tw")) {
            try it.need(1);
            s.word_spacing = try it.num(0);
        } else if (eql(u8, op, "Tz")) {
            try it.need(1);
            s.scale = try it.num(0) / 100;
        } else if (eql(u8, op, "TL")) {
            try it.need(1);
            s.leading = try it.num(0);
        } else if (eql(u8, op, "Ts")) {
            try it.need(1);
            s.rise = try it.num(0);
        } else if (eql(u8, op, "Td")) {
            try it.need(2);
            it.moveLine(try it.num(0), try it.num(1));
        } else if (eql(u8, op, "TD")) {
            try it.need(2);
            s.leading = -(try it.num(1));
            it.moveLine(try it.num(0), try it.num(1));
        } else if (eql(u8, op, "Tm")) {
            try it.need(6);
            it.tlm = .{ try it.num(0), try it.num(1), try it.num(2), try it.num(3), try it.num(4), try it.num(5) };
            it.tm = it.tlm;
        } else if (eql(u8, op, "T*")) {
            it.moveLine(0, -s.leading);
        } else if (eql(u8, op, "Tj")) {
            try it.need(1);
            try it.show(it.operands[0]);
        } else if (eql(u8, op, "'")) {
            try it.need(1);
            it.moveLine(0, -s.leading);
            try it.show(it.operands[0]);
        } else if (eql(u8, op, "\"")) {
            try it.need(3);
            s.word_spacing = try it.num(0);
            s.char_spacing = try it.num(1);
            it.moveLine(0, -s.leading);
            try it.show(it.operands[2]);
        } else if (eql(u8, op, "TJ")) {
            try it.need(1);
            if (it.operands[0] != .array) return error.BadContent;
            for (it.operands[0].array) |item| switch (item) {
                .string => try it.show(item),
                .integer, .real => {
                    const adj: f32 = @floatCast(item.number().?);
                    it.tm = mul(translate(-adj / 1000 * s.size * s.scale, 0), it.tm);
                },
                else => return error.BadContent,
            };
        }
    }

    fn moveLine(it: *Interpreter, tx: f32, ty: f32) void {
        it.tlm = mul(translate(tx, ty), it.tlm);
        it.tm = it.tlm;
    }

    fn font(it: *Interpreter, name: []const u8) Error!*const Font {
        for (it.fonts.items) |*e| if (std.mem.eql(u8, e.name, name)) return &e.font;
        const fonts = (try it.doc.get(it.resources, "Font")) orelse return error.BadContent;
        if (fonts != .dict) return error.BadContent;
        const fd = (try it.doc.get(fonts.dict, name)) orelse return error.BadContent;
        if (fd != .dict) return error.BadContent;
        try it.fonts.append(it.doc.a, .{ .name = name, .font = try Font.load(it.doc, fd.dict) });
        return &it.fonts.items[it.fonts.items.len - 1].font;
    }

    fn show(it: *Interpreter, o: syntax.Object) Error!void {
        if (o != .string) return error.BadContent;
        const s = &it.state;
        const f = s.font orelse return error.BadContent;
        var codes = f.codes(o.string);
        while (codes.next()) |code| {
            const trm = mul(mul(.{ s.size * s.scale, 0, 0, s.size, 0, s.rise }, it.tm), s.ctm);
            const page = mul(it.tm, s.ctm);
            var tx = f.width(code) / 1000 * s.size + s.char_spacing;
            // Word spacing applies only to the single-byte code 32.
            if (f.code_len == 1 and code == 32) tx += s.word_spacing;
            tx *= s.scale;

            var buf: [64]u8 = undefined;
            const t = f.text(code, &buf);
            var g: Glyph = .{
                .x = trm[4],
                .y = trm[5],
                .width = tx * std.math.hypot(page[0], page[1]),
                .size = @abs(s.size) * std.math.hypot(page[2], page[3]),
                .text_len = @intCast(@min(t.len, 16)),
                .text_buf = undefined,
            };
            @memcpy(g.text_buf[0..g.text_len], t[0..g.text_len]);
            try it.glyphs.append(it.doc.a, g);
            it.tm = mul(translate(tx, 0), it.tm);
        }
    }
};

/// Inline image data is binary; resume after `EI`.
fn skipInlineImage(lex: *syntax.Lexer) Error!void {
    const id = std.mem.indexOfPos(u8, lex.src, lex.pos, "ID") orelse return error.BadContent;
    var i = id + 2;
    while (i + 2 <= lex.src.len) : (i += 1) {
        if (syntax.isWhite(lex.src[i - 1]) and lex.src[i] == 'E' and lex.src[i + 1] == 'I' and
            (i + 2 == lex.src.len or syntax.isWhite(lex.src[i + 2])))
        {
            lex.pos = i + 2;
            return;
        }
    }
    return error.BadContent;
}

pub fn pageGlyphs(doc: *Document, page: Document.Page, glyphs: *std.ArrayList(Glyph)) Error!void {
    var it: Interpreter = .{ .doc = doc, .resources = page.resources, .glyphs = glyphs };
    try it.run(page.contents);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn testDoc(a: Allocator) !Document {
    const cmap = "1 beginbfrange <0000> <00FF> <0000> endbfrange";
    const objects = [_][]const u8{
        "<< /Type /Font /Subtype /Type0 /Encoding /Identity-H /DescendantFonts [2 0 R] /ToUnicode 3 0 R >>",
        "<< /Type /Font /Subtype /CIDFontType2 /DW 500 >>",
        std.fmt.comptimePrint("<< /Length {d} >>\nstream\n{s}\nendstream", .{ cmap.len, cmap }),
        "<< /Type /Font /Subtype /TrueType /FirstChar 32 /LastChar 32 /Widths [250] >>",
    };
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "%PDF-1.4\n");
    var offsets: [objects.len]usize = undefined;
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

fn run(a: Allocator, doc: *Document, content: []const u8) ![]Glyph {
    var p: syntax.Parser = .init(a, "<< /Font << /F1 1 0 R /F2 4 0 R >> >>");
    const res = (try p.object()).dict;
    var glyphs: std.ArrayList(Glyph) = .empty;
    try pageGlyphs(doc, .{ .resources = res, .contents = content }, &glyphs);
    return glyphs.items;
}

test "Tm, Tf, Tj place glyphs and advance by width" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try testDoc(a);
    const gs = try run(a, &doc, "BT /F1 10 Tf 1 0 0 1 100 700 Tm <00410042> Tj ET");
    try testing.expectEqual(@as(usize, 2), gs.len);
    try testing.expectEqualStrings("A", gs[0].text());
    try testing.expectEqual(@as(f32, 100), gs[0].x);
    try testing.expectEqual(@as(f32, 700), gs[0].y);
    try testing.expectEqual(@as(f32, 10), gs[0].size);
    // DW 500 at size 10 advances 5.
    try testing.expectEqual(@as(f32, 105), gs[1].x);
    try testing.expectEqual(@as(f32, 5), gs[1].width);
}

test "TJ adjustments, Td, Tc and cm" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try testDoc(a);
    const gs = try run(a, &doc, "q 2 0 0 2 10 20 cm BT /F1 10 Tf 1 Tc 5 6 Td [<0041> -1000 <0042>] TJ 0 -12 Td (\x00C) Tj ET Q");
    try testing.expectEqual(@as(usize, 3), gs.len);
    // Text space origin (5,6) scaled by 2 and moved by (10,20).
    try testing.expectEqual(@as(f32, 20), gs[0].x);
    try testing.expectEqual(@as(f32, 32), gs[0].y);
    try testing.expectEqual(@as(f32, 20), gs[0].size);
    // advance 5 + Tc 1, then -(-1000)/1000*10 = 10, all times 2.
    try testing.expectEqual(@as(f32, 52), gs[1].x);
    try testing.expectEqualStrings("C", gs[2].text());
    try testing.expectEqual(@as(f32, 20), gs[2].x);
    try testing.expectEqual(@as(f32, 8), gs[2].y);
}

test "word spacing only for single-byte space; q/Q restores state" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try testDoc(a);
    const gs = try run(a, &doc, "BT /F2 10 Tf 4 Tw 0 0 Td (  ) Tj ET q 3 Tw Q BT /F2 10 Tf ( ) Tj ET");
    try testing.expectEqual(@as(f32, 6.5), gs[0].width);
    try testing.expectEqual(@as(f32, 6.5), gs[1].x);
    try testing.expectEqual(@as(f32, 6.5), gs[2].width);
}

test "inline images and unknown operators are skipped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try testDoc(a);
    const gs = try run(a, &doc, "0 0 m 10 10 l S BI /W 1 /H 1 ID \x00\xff) EI BT /F1 10 Tf <0041> Tj ET");
    try testing.expectEqual(@as(usize, 1), gs.len);
}

test "malformed operators are rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var doc = try testDoc(a);
    try testing.expectError(error.BadContent, run(a, &doc, "BT (x) Tj ET"));
    try testing.expectError(error.BadContent, run(a, &doc, "BT /F9 10 Tf ET"));
    try testing.expectError(error.BadContent, run(a, &doc, "1 2 cm"));
}
