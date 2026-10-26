//! Stream filters (ISO 32000-1 §7.4). Only what the supported documents use.

const std = @import("std");
const Allocator = std.mem.Allocator;

const syntax = @import("syntax.zig");
const Ascii85 = @import("ascii85.zig").Ascii85;

pub const Error = error{ UnsupportedFilter, BadStream, StreamTooLong } || Allocator.Error;

/// Applies the stream's /Filter chain; `limit` caps every intermediate result.
pub fn decode(a: Allocator, dict: syntax.Dict, data: []const u8, limit: usize) Error![]const u8 {
    const filter = dict.get("Filter") orelse return data;
    const parms = dict.get("DecodeParms");
    switch (filter) {
        .name => |n| return apply(a, n, parmsAt(parms, 0), data, limit),
        .array => |names| {
            var out = data;
            for (names, 0..) |n, i| {
                if (n != .name) return error.BadStream;
                out = try apply(a, n.name, parmsAt(parms, i), out, limit);
            }
            return out;
        },
        else => return error.BadStream,
    }
}

fn parmsAt(parms: ?syntax.Object, i: usize) ?syntax.Object {
    const p = parms orelse return null;
    return switch (p) {
        .array => |items| if (i < items.len) items[i] else null,
        else => if (i == 0) p else null,
    };
}

fn apply(a: Allocator, name: []const u8, parms: ?syntax.Object, data: []const u8, limit: usize) Error![]const u8 {
    if (parms) |p| switch (p) {
        .null => {},
        .dict => |d| if (d.get("Predictor")) |pred| {
            if (pred != .integer or pred.integer > 1) return error.UnsupportedFilter;
        },
        else => return error.UnsupportedFilter,
    };
    if (std.mem.eql(u8, name, "FlateDecode")) return flate(a, data, limit);
    if (std.mem.eql(u8, name, "ASCII85Decode")) return ascii85(a, data, limit);
    return error.UnsupportedFilter;
}

fn flate(a: Allocator, data: []const u8, limit: usize) Error![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var z: std.compress.flate.Decompress = .init(&in, .zlib, &.{});
    return z.reader.allocRemaining(a, .limited(limit)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.StreamTooLong,
        else => error.BadStream,
    };
}

/// PDF's variant of Ascii85: optional `<~`, `~>` terminator, whitespace
/// anywhere, and `z` for a group of four zero bytes.
fn ascii85(a: Allocator, data: []const u8, limit: usize) Error![]u8 {
    var body = std.mem.trimStart(u8, data, " \t\r\n\x0c\x00");
    if (std.mem.startsWith(u8, body, "<~")) body = body[2..];
    if (std.mem.indexOf(u8, body, "~>")) |end| body = body[0..end];

    var len: usize = 0;
    var group: usize = 0;
    for (body) |c| {
        if (syntax.isWhite(c)) continue;
        if (c == 'z') {
            if (group != 0) return error.BadStream;
            len += 5;
            continue;
        }
        if (c < '!' or c > 'u') return error.BadStream;
        len += 1;
        group = (group + 1) % 5;
    }
    if (group == 1) return error.BadStream;
    if (len / 5 * 4 + 3 > limit) return error.StreamTooLong;

    const clean = try a.alloc(u8, len);
    var n: usize = 0;
    for (body) |c| {
        if (syntax.isWhite(c)) continue;
        if (c == 'z') {
            @memcpy(clean[n..][0..5], "!!!!!");
            n += 5;
        } else {
            clean[n] = c;
            n += 1;
        }
    }
    std.debug.assert(n == len);

    // Ascii85.decode would overflow its u32 on these.
    var i: usize = 0;
    while (i + 5 <= len) : (i += 5) {
        var v: u64 = 0;
        for (clean[i..][0..5]) |c| v = v * 85 + (c - '!');
        if (v > std.math.maxInt(u32)) return error.BadStream;
    }
    return Ascii85.decode(a, clean);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const content = "BT /F1 12 Tf 72 712 Td (Hello) Tj ET\n";
const content_zlib = [_]u8{
    0x78, 0x9c, 0x73, 0x0a, 0x51, 0xd0, 0x77, 0x33, 0x54, 0x30, 0x34, 0x52, 0x08, 0x49,
    0x53, 0x30, 0x37, 0x52, 0x30, 0x07, 0xb1, 0x52, 0x14, 0x34, 0x3c, 0x52, 0x73, 0x72,
    0xf2, 0x35, 0x15, 0x42, 0xb2, 0x14, 0x5c, 0x43, 0xb8, 0x00, 0xa0, 0x54, 0x08, 0xdb,
};
const content_a85_zlib = "<~Garg^;:'MC<%p.,#Y@rK2c;=7Yu28m4Ap6@nhh.KZ4pP2\\,`1$#ho~>";

fn dictOf(a: Allocator, src: []const u8) !syntax.Dict {
    var p: syntax.Parser = .init(a, src);
    return (try p.object()).dict;
}

test "no filter returns the data as is" {
    const data = "raw";
    try testing.expectEqual(data.ptr, (try decode(testing.allocator, .{}, data, 100)).ptr);
}

test "FlateDecode" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(content, try decode(a, try dictOf(a, "<< /Filter /FlateDecode >>"), &content_zlib, 1024));
    try testing.expectError(error.StreamTooLong, decode(a, try dictOf(a, "<< /Filter /FlateDecode >>"), &content_zlib, 10));
    try testing.expectError(error.BadStream, decode(a, try dictOf(a, "<< /Filter /FlateDecode >>"), content_zlib[0..20], 1024));
}

test "ASCII85Decode with whitespace, z and terminator" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try dictOf(a, "<< /Filter /ASCII85Decode >>");
    try testing.expectEqualStrings("Hello world", try decode(a, d, "<~87cU RD]j\n7BEbo7~>", 100));
    try testing.expectEqualStrings("\x00\x00\x00\x00abc", try decode(a, d, "z@:E^~>", 100));
    try testing.expectError(error.BadStream, decode(a, d, "87z~>", 100));
    try testing.expectError(error.BadStream, decode(a, d, "87c{U~>", 100));
    try testing.expectError(error.BadStream, decode(a, d, "uuuuu~>", 100));
    try testing.expectError(error.BadStream, decode(a, d, "87cURD~>", 100));
}

test "filter chains apply in order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try dictOf(a, "<< /Filter [/ASCII85Decode /FlateDecode] /DecodeParms [null null] >>");
    try testing.expectEqualStrings(content, try decode(a, d, content_a85_zlib, 1024));
}

test "unsupported filters and predictors are reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.UnsupportedFilter, decode(a, try dictOf(a, "<< /Filter /LZWDecode >>"), "x", 100));
    try testing.expectError(error.UnsupportedFilter, decode(a, try dictOf(a, "<< /Filter /FlateDecode /DecodeParms << /Predictor 12 >> >>"), &content_zlib, 100));
}
