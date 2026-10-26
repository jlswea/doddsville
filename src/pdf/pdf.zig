//! Minimal PDF reader for extracting positioned text from generated statements.

pub const syntax = @import("syntax.zig");
pub const filters = @import("filters.zig");
pub const Document = @import("Document.zig");
pub const CMap = @import("CMap.zig");
pub const Font = @import("Font.zig");
pub const text = @import("text.zig");
pub const layout = @import("layout.zig");

const std = @import("std");

pub const Error = text.Error;

pub const Page = struct { lines: []const layout.Line };

/// Reads `src` into lines of words per page. Everything is allocated from `a`
/// and may point into `src`; `decode_limit` caps every decoded stream.
pub fn extract(a: std.mem.Allocator, src: []const u8, decode_limit: usize) Error![]Page {
    var doc = try Document.open(a, src, decode_limit);
    const pages = try doc.pages();
    const out = try a.alloc(Page, pages.len);
    for (pages, out) |p, *o| {
        var glyphs: std.ArrayList(text.Glyph) = .empty;
        try text.pageGlyphs(&doc, p, &glyphs);
        o.* = .{ .lines = try layout.lines(a, glyphs.items) };
    }
    return out;
}

test {
    _ = @import("ascii85.zig");
    _ = syntax;
    _ = filters;
    _ = Document;
    _ = CMap;
    _ = Font;
    _ = text;
    _ = layout;
}
