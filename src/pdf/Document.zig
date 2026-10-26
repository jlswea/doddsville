//! A parsed PDF file: cross-reference table, trailer and object lookup
//! (ISO 32000-1 §7.5).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const syntax = @import("syntax.zig");
const filters = @import("filters.zig");
const Object = syntax.Object;
const Ref = syntax.Ref;

const Document = @This();

pub const Error = error{ BadXref, BadObject, TooManyObjects } || syntax.Error || filters.Error;

/// Upper bound on /Size; the documents we read have a few hundred objects.
pub const max_objects = 100_000;
/// Upper bound on incremental updates followed through /Prev.
const max_sections = 32;

pub const Entry = union(enum) {
    free,
    offset: usize,
};

a: Allocator,
src: []const u8,
entries: []Entry,
trailer: syntax.Dict,
/// Caps every decoded stream.
decode_limit: usize,

pub fn open(a: Allocator, src: []const u8, decode_limit: usize) Error!Document {
    var doc: Document = .{ .a = a, .src = src, .entries = &.{}, .trailer = .{}, .decode_limit = decode_limit };
    var offset: ?usize = try startXref(src);
    var sections: usize = 0;
    var seen: std.ArrayList(bool) = .empty;
    while (offset) |off| : (sections += 1) {
        if (sections == max_sections) return error.BadXref;
        const trailer = try doc.readSection(off, &seen);
        if (sections == 0) doc.trailer = trailer;
        offset = if (trailer.get("Prev")) |prev| try toOffset(prev, src.len) else null;
    }
    return doc;
}

fn startXref(src: []const u8) Error!usize {
    const tail_start = src.len -| 1024;
    const at = std.mem.lastIndexOf(u8, src[tail_start..], "startxref") orelse return error.BadXref;
    var lex: syntax.Lexer = .{ .src = src, .pos = tail_start + at + "startxref".len };
    const tok = (try lex.next()) orelse return error.BadXref;
    if (tok != .integer) return error.BadXref;
    return toOffset(.{ .integer = tok.integer }, src.len);
}

fn toOffset(o: Object, len: usize) Error!usize {
    if (o != .integer or o.integer < 0 or o.integer >= len) return error.BadXref;
    return @intCast(o.integer);
}

/// Older sections only fill entries the newer ones left unset.
fn readSection(doc: *Document, offset: usize, seen: *std.ArrayList(bool)) Error!syntax.Dict {
    var p: syntax.Parser = .init(doc.a, doc.src);
    p.lex.pos = offset;
    const kw = (try p.lex.next()) orelse return error.BadXref;
    if (kw != .keyword or !std.mem.eql(u8, kw.keyword, "xref")) return error.BadXref;

    while (true) {
        const tok = (try p.lex.next()) orelse return error.BadXref;
        if (tok == .keyword and std.mem.eql(u8, tok.keyword, "trailer")) break;
        const first = try intToken(tok);
        const count = try intToken((try p.lex.next()) orelse return error.BadXref);
        if (first + count > max_objects) return error.TooManyObjects;
        try doc.grow(seen, first + count);
        for (first..first + count) |num| {
            const off = try intToken((try p.lex.next()) orelse return error.BadXref);
            _ = try intToken((try p.lex.next()) orelse return error.BadXref);
            const kind = (try p.lex.next()) orelse return error.BadXref;
            if (kind != .keyword or kind.keyword.len != 1) return error.BadXref;
            if (seen.items[num]) continue;
            seen.items[num] = true;
            doc.entries[num] = switch (kind.keyword[0]) {
                'n' => if (off < doc.src.len) .{ .offset = off } else return error.BadXref,
                'f' => .free,
                else => return error.BadXref,
            };
        }
    }
    const trailer = try p.object();
    if (trailer != .dict) return error.BadXref;
    if (trailer.dict.get("Size")) |size| {
        if (size != .integer or size.integer < 0 or size.integer > max_objects) return error.TooManyObjects;
        try doc.grow(seen, @intCast(size.integer));
    }
    return trailer.dict;
}

fn intToken(tok: syntax.Token) Error!usize {
    if (tok != .integer or tok.integer < 0) return error.BadXref;
    return @intCast(tok.integer);
}

fn grow(doc: *Document, seen: *std.ArrayList(bool), len: usize) Error!void {
    if (len <= doc.entries.len) return;
    const old = doc.entries.len;
    doc.entries = if (old == 0) try doc.a.alloc(Entry, len) else try doc.a.realloc(doc.entries, len);
    @memset(doc.entries[old..], .free);
    try seen.appendNTimes(doc.a, false, len - old);
}

/// Missing and free objects are null, as the spec requires.
pub fn object(doc: *const Document, ref: Ref) Error!Object {
    if (ref.num >= doc.entries.len) return .null;
    return switch (doc.entries[ref.num]) {
        .free => .null,
        .offset => |off| doc.objectAt(off, ref),
    };
}

pub fn resolve(doc: *const Document, o: Object) Error!Object {
    return if (o == .ref) doc.object(o.ref) else o;
}

pub fn get(doc: *const Document, d: syntax.Dict, key: []const u8) Error!?Object {
    const v = d.get(key) orelse return null;
    return try doc.resolve(v);
}

fn objectAt(doc: *const Document, offset: usize, ref: Ref) Error!Object {
    var p: syntax.Parser = .init(doc.a, doc.src);
    p.lex.pos = offset;
    const num = (try p.lex.next()) orelse return error.BadObject;
    const gen = (try p.lex.next()) orelse return error.BadObject;
    const kw = (try p.lex.next()) orelse return error.BadObject;
    if (num != .integer or num.integer != ref.num or gen != .integer or
        kw != .keyword or !std.mem.eql(u8, kw.keyword, "obj")) return error.BadObject;

    const o = try p.object();
    if (o != .dict) return o;
    const save = p.lex.pos;
    const next = try p.lex.next();
    if (next == null or next.? != .keyword or !std.mem.eql(u8, next.?.keyword, "stream")) {
        p.lex.pos = save;
        return o;
    }
    return .{ .stream = .{ .dict = o.dict, .data = try doc.streamBytes(o.dict, p.lex.pos) } };
}

fn streamBytes(doc: *const Document, dict: syntax.Dict, after_keyword: usize) Error![]const u8 {
    var start = after_keyword;
    if (start < doc.src.len and doc.src[start] == '\r') start += 1;
    if (start < doc.src.len and doc.src[start] == '\n') start += 1;

    if (dict.get("Length")) |len_obj| {
        // An indirect /Length must not itself be a stream, or this recurses.
        const len = if (len_obj == .ref) try doc.object(len_obj.ref) else len_obj;
        if (len == .integer and len.integer >= 0 and start + @as(usize, @intCast(len.integer)) <= doc.src.len) {
            const end = start + @as(usize, @intCast(len.integer));
            var lex: syntax.Lexer = .{ .src = doc.src, .pos = end };
            if (try lex.next()) |t| if (t == .keyword and std.mem.eql(u8, t.keyword, "endstream"))
                return doc.src[start..end];
        }
    }
    // Wrong /Length: fall back to the endstream keyword.
    const end = std.mem.indexOfPos(u8, doc.src, start, "endstream") orelse return error.BadObject;
    return std.mem.trimEnd(u8, doc.src[start..end], "\r\n");
}

pub fn decodeStream(doc: *const Document, s: syntax.Stream) Error![]const u8 {
    return filters.decode(doc.a, s.dict, s.data, doc.decode_limit);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// Assembles a PDF from object bodies and computes the xref table.
fn buildPdf(a: Allocator, objects: []const []const u8, trailer_extra: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "%PDF-1.4\n%\xe2\xe3\xcf\xd3\n");
    const offsets = try a.alloc(usize, objects.len);
    for (objects, 0..) |body, i| {
        offsets[i] = out.items.len;
        try out.print(a, "{d} 0 obj\n{s}\nendobj\n", .{ i + 1, body });
    }
    const xref = out.items.len;
    try out.print(a, "xref\n0 {d}\n0000000000 65535 f \n", .{objects.len + 1});
    for (offsets) |off| try out.print(a, "{d:0>10} 00000 n \n", .{off});
    try out.print(a, "trailer\n<< /Size {d} /Root 1 0 R {s}>>\nstartxref\n{d}\n%%EOF\n", .{ objects.len + 1, trailer_extra, xref });
    return out.items;
}

test "objects resolve through the xref table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try buildPdf(a, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [] /Count 0 >>",
    }, "");
    const doc = try Document.open(a, src, 1024);
    const root = (try doc.get(doc.trailer, "Root")).?.dict;
    try testing.expect(root.get("Type").?.isName("Catalog"));
    const pages = (try doc.get(root, "Pages")).?.dict;
    try testing.expectEqual(@as(i64, 0), pages.get("Count").?.integer);
    try testing.expect((try doc.object(.{ .num = 0, .gen = 0 })) == .null);
    try testing.expect((try doc.object(.{ .num = 99, .gen = 0 })) == .null);
}

test "streams with direct, indirect and wrong /Length" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try buildPdf(a, &.{
        "<< /Type /Catalog >>",
        "<< /Length 5 >>\nstream\r\nhello\nendstream",
        "<< /Length 4 0 R >>\nstream\nworld\nendstream",
        "5",
        "<< /Length 99 >>\nstream\nwrong\nendstream",
    }, "");
    const doc = try Document.open(a, src, 1024);
    for ([_][]const u8{ "hello", "world", "wrong" }, [_]u32{ 2, 3, 5 }) |want, num| {
        const s = (try doc.object(.{ .num = num, .gen = 0 })).stream;
        try testing.expectEqualStrings(want, try doc.decodeStream(s));
    }
}

test "incremental updates: the newest entry wins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try buildPdf(a, &.{ "<< /Type /Catalog >>", "(old)" }, "");
    const prev = std.mem.lastIndexOf(u8, base, "\nxref\n").? + 1;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, base);
    const obj = out.items.len;
    try out.appendSlice(a, "2 0 obj\n(new)\nendobj\n");
    const xref = out.items.len;
    try out.print(a, "xref\n2 1\n{d:0>10} 00000 n \ntrailer\n<< /Size 3 /Root 1 0 R /Prev {d} >>\nstartxref\n{d}\n%%EOF\n", .{ obj, prev, xref });

    const doc = try Document.open(a, out.items, 1024);
    try testing.expectEqualStrings("new", (try doc.object(.{ .num = 2, .gen = 0 })).string);
    try testing.expect((try doc.object(.{ .num = 1, .gen = 0 })) == .dict);
}

test "broken files are rejected, not trusted" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.BadXref, Document.open(a, "%PDF-1.4\nno xref here", 1024));
    try testing.expectError(error.BadXref, Document.open(a, "startxref\n999999\n%%EOF", 1024));
    try testing.expectError(error.TooManyObjects, Document.open(a, "xref\n0 1000000\ntrailer<<>>\nstartxref\n0\n", 1024));

    const src = try buildPdf(a, &.{ "<< /Type /Catalog >>", "(x)" }, "");
    const doc = try Document.open(a, src, 1024);
    // An xref entry pointing at the wrong object number.
    doc.entries[2] = doc.entries[1];
    try testing.expectError(error.BadObject, doc.object(.{ .num = 2, .gen = 0 }));
}

test "a /Prev cycle stops at max_sections" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "xref\n0 1\n0000000000 65535 f \ntrailer\n<< /Size 1 /Prev 0 >>\nstartxref\n0\n%%EOF\n";
    try testing.expectError(error.BadXref, Document.open(a, src, 1024));
}
