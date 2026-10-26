//! Groups positioned glyphs into words and lines, top to bottom, left to right.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Glyph = @import("text.zig").Glyph;

pub const Word = struct {
    x0: f32,
    x1: f32,
    /// Baseline, y up.
    y: f32,
    size: f32,
    text: []const u8,
};

pub const Line = struct {
    y: f32,
    words: []const Word,
    /// Words joined by single spaces.
    text: []const u8,
};

/// Glyphs whose baselines differ by less than this fraction of the font size share a line.
const line_tolerance = 0.3;
/// A horizontal gap wider than this fraction of the font size starts a new word.
const word_gap = 0.1;

fn isBlank(s: []const u8) bool {
    for (s) |c| if (c != ' ' and c != '\t' and c != 0xa0 and c != 0xc2) return false;
    return true;
}

pub fn lines(a: Allocator, glyphs: []const Glyph) Allocator.Error![]Line {
    const order = try a.alloc(u32, glyphs.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u32, order, glyphs, struct {
        fn lt(gs: []const Glyph, x: u32, y: u32) bool {
            return gs[x].y > gs[y].y or (gs[x].y == gs[y].y and gs[x].x < gs[y].x);
        }
    }.lt);

    var out: std.ArrayList(Line) = .empty;
    var start: usize = 0;
    while (start < order.len) {
        const first = glyphs[order[start]];
        const tol = @max(first.size * line_tolerance, 1.0);
        var end = start + 1;
        while (end < order.len and first.y - glyphs[order[end]].y <= tol) end += 1;
        const members = order[start..end];
        std.mem.sort(u32, members, glyphs, struct {
            fn lt(gs: []const Glyph, x: u32, y: u32) bool {
                return gs[x].x < gs[y].x;
            }
        }.lt);
        if (try line(a, glyphs, members)) |l| try out.append(a, l);
        start = end;
    }
    return out.items;
}

fn line(a: Allocator, glyphs: []const Glyph, members: []const u32) Allocator.Error!?Line {
    var words: std.ArrayList(Word) = .empty;
    var buf: std.ArrayList(u8) = .empty;
    var cur: ?Word = null;
    var prev_end: f32 = 0;
    for (members) |gi| {
        const g = &glyphs[gi];
        const t = g.text();
        if (isBlank(t)) {
            if (cur) |w| try finish(a, &words, &buf, w);
            cur = null;
            continue;
        }
        if (cur) |*w| {
            if (g.x - prev_end > g.size * word_gap) {
                try finish(a, &words, &buf, w.*);
                cur = null;
            }
        }
        if (cur == null) cur = .{ .x0 = g.x, .x1 = g.x, .y = g.y, .size = g.size, .text = "" };
        try buf.appendSlice(a, t);
        cur.?.x1 = g.x + g.width;
        prev_end = g.x + g.width;
    }
    if (cur) |w| try finish(a, &words, &buf, w);
    if (words.items.len == 0) return null;

    var text: std.ArrayList(u8) = .empty;
    for (words.items, 0..) |w, i| {
        if (i > 0) try text.append(a, ' ');
        try text.appendSlice(a, w.text);
    }
    return .{ .y = words.items[0].y, .words = words.items, .text = text.items };
}

fn finish(a: Allocator, words: *std.ArrayList(Word), buf: *std.ArrayList(u8), w: Word) Allocator.Error!void {
    var done = w;
    done.text = try a.dupe(u8, buf.items);
    buf.clearRetainingCapacity();
    try words.append(a, done);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn glyph(x: f32, y: f32, t: []const u8) Glyph {
    var g: Glyph = .{ .x = x, .y = y, .width = 5, .size = 10, .text_len = @intCast(t.len), .text_buf = undefined };
    @memcpy(g.text_buf[0..t.len], t);
    return g;
}

test "glyphs become words and lines in reading order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gs = [_]Glyph{
        // second line, out of order
        glyph(105, 680, "b"),  glyph(100, 680, "a"),
        // first line: "Betrag" then a column gap, with jittered baselines
        glyph(10, 700, "B"),   glyph(15, 700.5, "e"),
        glyph(20, 699.8, "t"), glyph(200, 700, "1"),
        glyph(205, 700, ","),  glyph(210, 700, "5"),
        // explicit space glyph splits words
        glyph(100, 660, "x"),  glyph(105, 660, " "),
        glyph(110, 660, "y"),
    };
    const ls = try lines(a, &gs);
    try testing.expectEqual(@as(usize, 3), ls.len);
    try testing.expectEqualStrings("Bet 1,5", ls[0].text);
    try testing.expectEqual(@as(usize, 2), ls[0].words.len);
    try testing.expectEqual(@as(f32, 10), ls[0].words[0].x0);
    try testing.expectEqual(@as(f32, 25), ls[0].words[0].x1);
    try testing.expectEqual(@as(f32, 200), ls[0].words[1].x0);
    try testing.expectEqualStrings("ab", ls[1].text);
    try testing.expectEqualStrings("x y", ls[2].text);
}

test "blank-only lines are dropped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gs = [_]Glyph{ glyph(0, 10, " "), glyph(5, 10, " ") };
    try testing.expectEqual(@as(usize, 0), (try lines(arena.allocator(), &gs)).len);
}
