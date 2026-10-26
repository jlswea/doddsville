//! A parsed PDF file: cross-reference table, trailer and object lookup
//! (ISO 32000-1 §7.5).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const syntax = @import("syntax.zig");
pub const CMap = @import("CMap.zig");
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
    /// Object number `index`th in object stream `stream`.
    compressed: struct { stream: u32, index: u32 },
};

/// A decoded object stream: `pairs` holds object number and offset, interleaved.
const ObjStm = struct { num: u32, first: usize, pairs: []const usize, data: []const u8 };

a: Allocator,
src: []const u8,
entries: []Entry,
trailer: syntax.Dict,
/// Caps every decoded stream.
decode_limit: usize,
objstms: std.ArrayList(ObjStm) = .empty,

/// The result refers into `src`, which must outlive it.
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
    if (kw == .integer) return doc.readXrefStream(offset, try intToken(kw), seen);
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

/// ISO 32000-1 §7.5.8: binary rows of `/W` big-endian fields.
fn readXrefStream(doc: *Document, offset: usize, num: usize, seen: *std.ArrayList(bool)) Error!syntax.Dict {
    if (num > std.math.maxInt(u32)) return error.BadXref;
    const o = doc.objectAt(offset, .{ .num = @intCast(num), .gen = 0 }) catch return error.BadXref;
    if (o != .stream or !o.stream.dict.hasName("Type", "XRef")) return error.BadXref;
    const dict = o.stream.dict;

    const size_obj = dict.get("Size") orelse return error.BadXref;
    if (size_obj != .integer or size_obj.integer < 0) return error.BadXref;
    if (size_obj.integer > max_objects) return error.TooManyObjects;
    const size: usize = @intCast(size_obj.integer);
    try doc.grow(seen, size);

    var w: [3]usize = undefined;
    const w_obj = dict.get("W") orelse return error.BadXref;
    if (w_obj != .array or w_obj.array.len != 3) return error.BadXref;
    for (w_obj.array, &w) |x, *wi| {
        if (x != .integer or x.integer < 0 or x.integer > 8) return error.BadXref;
        wi.* = @intCast(x.integer);
    }
    const row_len = w[0] + w[1] + w[2];
    if (row_len == 0) return error.BadXref;

    const default_index = [_]Object{ .{ .integer = 0 }, size_obj };
    const index: []const Object = if (dict.get("Index")) |ix| (if (ix == .array) ix.array else return error.BadXref) else &default_index;
    if (index.len % 2 != 0) return error.BadXref;

    const data = try doc.decodeStream(o.stream);
    var row: usize = 0;
    var i: usize = 0;
    while (i < index.len) : (i += 2) {
        if (index[i] != .integer or index[i + 1] != .integer or index[i].integer < 0 or index[i + 1].integer < 0) return error.BadXref;
        const first: usize = @intCast(index[i].integer);
        const count: usize = @intCast(index[i + 1].integer);
        if (first + count > size) return error.BadXref;
        for (first..first + count) |n| {
            if ((row + 1) * row_len > data.len) return error.BadXref;
            const r = data[row * row_len ..][0..row_len];
            row += 1;
            const kind = if (w[0] == 0) 1 else field(r[0..w[0]]);
            const f2 = field(r[w[0]..][0..w[1]]);
            const f3 = field(r[w[0] + w[1] ..][0..w[2]]);
            if (seen.items[n]) continue;
            seen.items[n] = true;
            doc.entries[n] = switch (kind) {
                0 => .free,
                1 => if (f2 < doc.src.len) .{ .offset = @intCast(f2) } else return error.BadXref,
                2 => if (f2 <= std.math.maxInt(u32) and f3 <= std.math.maxInt(u32))
                    .{ .compressed = .{ .stream = @intCast(f2), .index = @intCast(f3) } }
                else
                    return error.BadXref,
                // Reserved types must be treated as references to the null object.
                else => .free,
            };
        }
    }
    return dict;
}

fn field(bytes: []const u8) u64 {
    var v: u64 = 0;
    for (bytes) |b| v = v << 8 | b;
    return v;
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
pub fn object(doc: *Document, ref: Ref) Error!Object {
    if (ref.num >= doc.entries.len) return .null;
    return switch (doc.entries[ref.num]) {
        .free => .null,
        .offset => |off| doc.objectAt(off, ref),
        .compressed => |c| doc.compressedObject(ref.num, c.stream, c.index),
    };
}

pub fn resolve(doc: *Document, o: Object) Error!Object {
    return if (o == .ref) doc.object(o.ref) else o;
}

pub fn get(doc: *Document, d: syntax.Dict, key: []const u8) Error!?Object {
    const v = d.get(key) orelse return null;
    return try doc.resolve(v);
}

fn compressedObject(doc: *Document, num: u32, stream: u32, index: u32) Error!Object {
    const os = try doc.objStm(stream);
    if (index >= os.pairs.len / 2 or os.pairs[2 * index] != num) return error.BadObject;
    const off = os.first + os.pairs[2 * index + 1];
    if (off >= os.data.len) return error.BadObject;
    var p: syntax.Parser = .init(doc.a, os.data);
    p.lex.pos = off;
    return p.object();
}

/// Decoded once and cached: the arena never frees, so re-decoding would leak.
fn objStm(doc: *Document, num: u32) Error!ObjStm {
    for (doc.objstms.items) |os| if (os.num == num) return os;
    if (num >= doc.entries.len or doc.entries[num] != .offset) return error.BadObject;
    const o = try doc.objectAt(doc.entries[num].offset, .{ .num = num, .gen = 0 });
    if (o != .stream or !o.stream.dict.hasName("Type", "ObjStm")) return error.BadObject;
    const n = o.stream.dict.get("N") orelse return error.BadObject;
    const first = o.stream.dict.get("First") orelse return error.BadObject;
    if (n != .integer or first != .integer or n.integer < 0 or first.integer < 0 or n.integer > max_objects) return error.BadObject;

    const data = try doc.decodeStream(o.stream);
    const pairs = try doc.a.alloc(usize, 2 * @as(usize, @intCast(n.integer)));
    var lex: syntax.Lexer = .{ .src = data };
    for (pairs) |*v| {
        const tok = (try lex.next()) orelse return error.BadObject;
        v.* = intToken(tok) catch return error.BadObject;
    }
    const os: ObjStm = .{ .num = num, .first = @intCast(first.integer), .pairs = pairs, .data = data };
    try doc.objstms.append(doc.a, os);
    return os;
}

fn objectAt(doc: *Document, offset: usize, ref: Ref) Error!Object {
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

fn streamBytes(doc: *Document, dict: syntax.Dict, after_keyword: usize) Error![]const u8 {
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

/// Upper bound on pages; statements have a handful.
pub const max_pages = 1000;

pub const Page = struct {
    resources: syntax.Dict,
    /// All content streams, decoded and joined.
    contents: []const u8,
};

pub fn pages(doc: *Document) Error![]Page {
    const root = (try doc.get(doc.trailer, "Root")) orelse return error.BadObject;
    if (root != .dict) return error.BadObject;
    const tree = (try doc.get(root.dict, "Pages")) orelse return error.BadObject;
    if (tree != .dict) return error.BadObject;
    var list: std.ArrayList(Page) = .empty;
    try doc.walk(tree.dict, .{}, &list, 0);
    return list.items;
}

fn walk(doc: *Document, node: syntax.Dict, inherited: syntax.Dict, list: *std.ArrayList(Page), depth: usize) Error!void {
    if (depth > syntax.max_depth) return error.TooDeep;
    const resources = if (try doc.get(node, "Resources")) |r| (if (r == .dict) r.dict else return error.BadObject) else inherited;
    if (try doc.get(node, "Kids")) |kids| {
        if (kids != .array) return error.BadObject;
        for (kids.array) |k| {
            const kid = try doc.resolve(k);
            if (kid != .dict) return error.BadObject;
            try doc.walk(kid.dict, resources, list, depth + 1);
        }
        return;
    }
    if (list.items.len == max_pages) return error.TooManyObjects;
    try list.append(doc.a, .{ .resources = resources, .contents = try doc.contents(node) });
}

fn contents(doc: *Document, page: syntax.Dict) Error![]const u8 {
    const c = (try doc.get(page, "Contents")) orelse return "";
    switch (c) {
        .stream => |s| return doc.decodeStream(s),
        .array => |parts| {
            var out: std.ArrayList(u8) = .empty;
            for (parts) |part| {
                const s = try doc.resolve(part);
                if (s != .stream) return error.BadObject;
                try out.appendSlice(doc.a, try doc.decodeStream(s.stream));
                // Streams may split between tokens but never inside one.
                try out.append(doc.a, '\n');
            }
            return out.items;
        },
        else => return error.BadObject,
    }
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
    var doc = try Document.open(a, src, 1024);
    const root = (try doc.get(doc.trailer, "Root")).?.dict;
    try testing.expect(root.get("Type").?.isName("Catalog"));
    const tree = (try doc.get(root, "Pages")).?.dict;
    try testing.expectEqual(@as(i64, 0), tree.get("Count").?.integer);
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
    var doc = try Document.open(a, src, 1024);
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

    var doc = try Document.open(a, out.items, 1024);
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
    var doc = try Document.open(a, src, 1024);
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

test "xref streams and object streams" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "%PDF-1.7\n");
    const catalog = out.items.len;
    try out.appendSlice(a, "1 0 obj\n<< /Type /Catalog /Pages 3 0 R >>\nendobj\n");
    const objstm = out.items.len;
    const body = "3 0 4 28 << /Type /Pages /Count 7 >> (inside)";
    try out.print(a, "2 0 obj\n<< /Type /ObjStm /N 2 /First 9 /Length {d} >>\nstream\n{s}\nendstream\nendobj\n", .{ body.len, body });
    const xref = out.items.len;
    // W [1 2 1]: type, offset or object stream number, generation or index.
    var rows: std.ArrayList(u8) = .empty;
    for ([_][3]usize{ .{ 0, 0, 255 }, .{ 1, catalog, 0 }, .{ 1, objstm, 0 }, .{ 2, 2, 0 }, .{ 2, 2, 1 }, .{ 1, xref, 0 } }) |r| {
        try rows.appendSlice(a, &.{ @intCast(r[0]), @intCast(r[1] >> 8), @intCast(r[1] & 0xff), @intCast(r[2]) });
    }
    try out.print(a, "5 0 obj\n<< /Type /XRef /Size 6 /W [1 2 1] /Index [0 6] /Root 1 0 R /Length {d} >>\nstream\n", .{rows.items.len});
    try out.appendSlice(a, rows.items);
    try out.print(a, "\nendstream\nendobj\nstartxref\n{d}\n%%EOF\n", .{xref});

    var doc = try Document.open(a, out.items, 1024);
    const root = (try doc.get(doc.trailer, "Root")).?.dict;
    const tree = (try doc.get(root, "Pages")).?.dict;
    try testing.expectEqual(@as(i64, 7), tree.get("Count").?.integer);
    try testing.expectEqualStrings("inside", (try doc.object(.{ .num = 4, .gen = 0 })).string);
    try testing.expectEqual(@as(usize, 1), doc.objstms.items.len);
    _ = try doc.object(.{ .num = 3, .gen = 0 });
    try testing.expectEqual(@as(usize, 1), doc.objstms.items.len);
}

test "page tree: inherited resources and content arrays" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try buildPdf(a, &.{
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 /Resources << /Font << /F1 7 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /Contents 5 0 R >>",
        "<< /Type /Page /Parent 2 0 R /Contents [5 0 R 6 0 R] /Resources << /Font << /F2 7 0 R >> >> >>",
        "<< /Length 5 >>\nstream\nBT ET\nendstream",
        "<< /Length 1 >>\nstream\nq\nendstream",
        "<< /Type /Font >>",
    }, "");
    var doc = try Document.open(a, src, 1024);
    const ps = try doc.pages();
    try testing.expectEqual(@as(usize, 2), ps.len);
    try testing.expect(ps[0].resources.get("Font").?.dict.get("F1") != null);
    try testing.expectEqualStrings("BT ET", ps[0].contents);
    try testing.expect(ps[1].resources.get("Font").?.dict.get("F2") != null);
    try testing.expectEqualStrings("BT ET\nq\n", ps[1].contents);
}
