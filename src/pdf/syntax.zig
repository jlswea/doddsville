//! PDF tokens and objects (ISO 32000-1 §7.2–7.3).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ Syntax, TooDeep } || Allocator.Error;

/// Bounds recursion on untrusted input.
pub const max_depth = 32;

pub fn isWhite(c: u8) bool {
    return switch (c) {
        0, '\t', '\n', 0x0c, '\r', ' ' => true,
        else => false,
    };
}

pub fn isDelimiter(c: u8) bool {
    return switch (c) {
        '(', ')', '<', '>', '[', ']', '{', '}', '/', '%' => true,
        else => false,
    };
}

fn isRegular(c: u8) bool {
    return !isWhite(c) and !isDelimiter(c);
}

pub const Token = union(enum) {
    integer: i64,
    real: f64,
    /// Without the leading '/', `#xx` escapes intact.
    name: []const u8,
    /// Between the outer parentheses, escapes intact.
    literal: []const u8,
    /// Between '<' and '>'.
    hex: []const u8,
    array_begin,
    array_end,
    dict_begin,
    dict_end,
    keyword: []const u8,
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,

    pub fn skipWhite(l: *Lexer) void {
        while (l.pos < l.src.len) {
            const c = l.src[l.pos];
            if (isWhite(c)) {
                l.pos += 1;
            } else if (c == '%') {
                while (l.pos < l.src.len and l.src[l.pos] != '\n' and l.src[l.pos] != '\r') l.pos += 1;
            } else break;
        }
    }

    pub fn next(l: *Lexer) Error!?Token {
        l.skipWhite();
        if (l.pos >= l.src.len) return null;
        const start = l.pos;
        switch (l.src[start]) {
            '[' => {
                l.pos += 1;
                return .array_begin;
            },
            ']' => {
                l.pos += 1;
                return .array_end;
            },
            '<' => {
                if (l.peekAt(start + 1) == '<') {
                    l.pos += 2;
                    return .dict_begin;
                }
                const end = std.mem.indexOfScalarPos(u8, l.src, start + 1, '>') orelse return error.Syntax;
                l.pos = end + 1;
                return .{ .hex = l.src[start + 1 .. end] };
            },
            '>' => {
                if (l.peekAt(start + 1) != '>') return error.Syntax;
                l.pos += 2;
                return .dict_end;
            },
            '(' => return .{ .literal = try l.literal() },
            ')' => return error.Syntax,
            '/' => {
                l.pos += 1;
                while (l.pos < l.src.len and isRegular(l.src[l.pos])) l.pos += 1;
                return .{ .name = l.src[start + 1 .. l.pos] };
            },
            '{', '}' => {
                l.pos += 1;
                return .{ .keyword = l.src[start..l.pos] };
            },
            else => {
                while (l.pos < l.src.len and isRegular(l.src[l.pos])) l.pos += 1;
                const run = l.src[start..l.pos];
                return number(run) orelse .{ .keyword = run };
            },
        }
    }

    fn peekAt(l: *const Lexer, i: usize) ?u8 {
        return if (i < l.src.len) l.src[i] else null;
    }

    fn literal(l: *Lexer) Error![]const u8 {
        const start = l.pos + 1;
        var depth: usize = 1;
        var i = start;
        while (i < l.src.len) : (i += 1) {
            switch (l.src[i]) {
                '\\' => i += 1,
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) {
                        l.pos = i + 1;
                        return l.src[start..i];
                    }
                },
                else => {},
            }
        }
        return error.Syntax;
    }
};

/// `[+-]?(\d+\.?\d*|\.\d+)`; anything else is a keyword.
fn number(run: []const u8) ?Token {
    var i: usize = 0;
    if (i < run.len and (run[i] == '+' or run[i] == '-')) i += 1;
    var digits: usize = 0;
    var dot = false;
    while (i < run.len) : (i += 1) {
        switch (run[i]) {
            '0'...'9' => digits += 1,
            '.' => {
                if (dot) return null;
                dot = true;
            },
            else => return null,
        }
    }
    if (digits == 0) return null;
    if (!dot) {
        if (std.fmt.parseInt(i64, run, 10)) |n| return .{ .integer = n } else |_| {}
    }
    // std.fmt.parseFloat rejects "4." and ".5", which PDF writers emit.
    var buf: [64]u8 = undefined;
    if (run.len + 2 > buf.len) return null;
    var n: usize = 0;
    var j: usize = 0;
    if (run[0] == '+' or run[0] == '-') {
        buf[0] = run[0];
        n = 1;
        j = 1;
    }
    if (run[j] == '.') {
        buf[n] = '0';
        n += 1;
    }
    @memcpy(buf[n..][0 .. run.len - j], run[j..]);
    n += run.len - j;
    if (buf[n - 1] == '.') {
        buf[n] = '0';
        n += 1;
    }
    const r = std.fmt.parseFloat(f64, buf[0..n]) catch return null;
    return .{ .real = r };
}

pub const Ref = struct { num: u32, gen: u16 };

/// Only produced by Document: streams are always indirect objects.
pub const Stream = struct {
    dict: Dict,
    /// Still encoded.
    data: []const u8,
};

pub const Object = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    real: f64,
    name: []const u8,
    string: []const u8,
    array: []const Object,
    dict: Dict,
    ref: Ref,
    stream: Stream,

    pub fn number(o: Object) ?f64 {
        return switch (o) {
            .integer => |n| @floatFromInt(n),
            .real => |r| r,
            else => null,
        };
    }

    pub fn isName(o: Object, n: []const u8) bool {
        return o == .name and std.mem.eql(u8, o.name, n);
    }
};

pub const Dict = struct {
    keys: []const []const u8 = &.{},
    values: []const Object = &.{},

    pub fn get(d: Dict, key: []const u8) ?Object {
        for (d.keys, d.values) |k, v| if (std.mem.eql(u8, k, key)) return v;
        return null;
    }

    pub fn hasName(d: Dict, key: []const u8, n: []const u8) bool {
        const v = d.get(key) orelse return false;
        return v.isName(n);
    }
};

pub const Parser = struct {
    lex: Lexer,
    a: Allocator,

    pub fn init(a: Allocator, src: []const u8) Parser {
        return .{ .lex = .{ .src = src }, .a = a };
    }

    pub fn object(p: *Parser) Error!Object {
        const tok = (try p.lex.next()) orelse return error.Syntax;
        return p.fromToken(tok, 0);
    }

    /// Converts an already lexed token; content streams lex operators themselves.
    pub fn fromToken(p: *Parser, tok: Token, depth: usize) Error!Object {
        if (depth > max_depth) return error.TooDeep;
        return switch (tok) {
            .integer => |n| p.maybeRef(n),
            .real => |r| .{ .real = r },
            .name => |raw| .{ .name = try decodeName(p.a, raw) },
            .literal => |raw| .{ .string = try decodeLiteral(p.a, raw) },
            .hex => |raw| .{ .string = try decodeHex(p.a, raw) },
            .array_begin => p.array(depth),
            .dict_begin => p.dict(depth),
            .keyword => |k| if (std.mem.eql(u8, k, "true"))
                .{ .boolean = true }
            else if (std.mem.eql(u8, k, "false"))
                .{ .boolean = false }
            else if (std.mem.eql(u8, k, "null"))
                .null
            else
                error.Syntax,
            .array_end, .dict_end => error.Syntax,
        };
    }

    fn maybeRef(p: *Parser, n: i64) Error!Object {
        const save = p.lex.pos;
        if (n >= 0 and n <= std.math.maxInt(u32)) {
            if (try p.lex.next()) |t1| if (t1 == .integer and t1.integer >= 0 and t1.integer <= std.math.maxInt(u16)) {
                if (try p.lex.next()) |t2| if (t2 == .keyword and std.mem.eql(u8, t2.keyword, "R")) {
                    return .{ .ref = .{ .num = @intCast(n), .gen = @intCast(t1.integer) } };
                };
            };
        }
        p.lex.pos = save;
        return .{ .integer = n };
    }

    fn array(p: *Parser, depth: usize) Error!Object {
        var items: std.ArrayList(Object) = .empty;
        while (true) {
            const tok = (try p.lex.next()) orelse return error.Syntax;
            if (tok == .array_end) return .{ .array = try items.toOwnedSlice(p.a) };
            try items.append(p.a, try p.fromToken(tok, depth + 1));
        }
    }

    fn dict(p: *Parser, depth: usize) Error!Object {
        var keys: std.ArrayList([]const u8) = .empty;
        var values: std.ArrayList(Object) = .empty;
        while (true) {
            const tok = (try p.lex.next()) orelse return error.Syntax;
            if (tok == .dict_end) return .{ .dict = .{
                .keys = try keys.toOwnedSlice(p.a),
                .values = try values.toOwnedSlice(p.a),
            } };
            if (tok != .name) return error.Syntax;
            try keys.append(p.a, try decodeName(p.a, tok.name));
            const v = (try p.lex.next()) orelse return error.Syntax;
            try values.append(p.a, try p.fromToken(v, depth + 1));
        }
    }
};

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub fn decodeName(a: Allocator, raw: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '#') == null) return raw;
    const out = try a.alloc(u8, raw.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '#') {
            if (i + 2 >= raw.len) return error.Syntax;
            const hi = hexValue(raw[i + 1]) orelse return error.Syntax;
            const lo = hexValue(raw[i + 2]) orelse return error.Syntax;
            out[n] = hi << 4 | lo;
            i += 2;
        } else out[n] = raw[i];
        n += 1;
    }
    return out[0..n];
}

pub fn decodeLiteral(a: Allocator, raw: []const u8) Error![]const u8 {
    if (std.mem.indexOfAny(u8, raw, "\\\r") == null) return raw;
    const out = try a.alloc(u8, raw.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '\r') {
            // A bare end-of-line in a literal string means a single LF.
            out[n] = '\n';
            n += 1;
            if (i + 1 < raw.len and raw[i + 1] == '\n') i += 1;
            continue;
        }
        if (c != '\\') {
            out[n] = c;
            n += 1;
            continue;
        }
        i += 1;
        if (i >= raw.len) return error.Syntax;
        const e = raw[i];
        switch (e) {
            'n' => out[n] = '\n',
            'r' => out[n] = '\r',
            't' => out[n] = '\t',
            'b' => out[n] = 0x08,
            'f' => out[n] = 0x0c,
            '0'...'7' => {
                var v: u32 = e - '0';
                var k: usize = 1;
                while (k < 3 and i + 1 < raw.len and raw[i + 1] >= '0' and raw[i + 1] <= '7') : (k += 1) {
                    i += 1;
                    v = v * 8 + (raw[i] - '0');
                }
                out[n] = @truncate(v);
            },
            '\r' => {
                if (i + 1 < raw.len and raw[i + 1] == '\n') i += 1;
                continue;
            },
            '\n' => continue,
            else => out[n] = e,
        }
        n += 1;
    }
    return out[0..n];
}

pub fn decodeHex(a: Allocator, raw: []const u8) Error![]const u8 {
    const out = try a.alloc(u8, raw.len / 2 + 1);
    var n: usize = 0;
    var hi: ?u8 = null;
    for (raw) |c| {
        if (isWhite(c)) continue;
        const v = hexValue(c) orelse return error.Syntax;
        if (hi) |h| {
            out[n] = h << 4 | v;
            n += 1;
            hi = null;
        } else hi = v;
    }
    if (hi) |h| {
        out[n] = h << 4;
        n += 1;
    }
    return out[0..n];
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

fn parseOne(a: Allocator, src: []const u8) !Object {
    var p: Parser = .init(a, src);
    return p.object();
}

test "lexer splits tokens and skips comments" {
    var l: Lexer = .{ .src = "% header\n/Type/Page[1 -2.5]<<>> Tj" };
    try testing.expectEqualStrings("Type", (try l.next()).?.name);
    try testing.expectEqualStrings("Page", (try l.next()).?.name);
    try testing.expect((try l.next()).? == .array_begin);
    try testing.expectEqual(@as(i64, 1), (try l.next()).?.integer);
    try testing.expectEqual(@as(f64, -2.5), (try l.next()).?.real);
    try testing.expect((try l.next()).? == .array_end);
    try testing.expect((try l.next()).? == .dict_begin);
    try testing.expect((try l.next()).? == .dict_end);
    try testing.expectEqualStrings("Tj", (try l.next()).?.keyword);
    try testing.expect((try l.next()) == null);
}

test "numbers PDF writers emit" {
    try testing.expectEqual(@as(f64, 4.0), number("4.").?.real);
    try testing.expectEqual(@as(f64, -0.5), number("-.5").?.real);
    try testing.expectEqual(@as(f64, 0.25), number("+.25").?.real);
    try testing.expectEqual(@as(i64, -17), number("-17").?.integer);
    try testing.expect(number("1.2.3") == null);
    try testing.expect(number("-") == null);
    try testing.expect(number("Td") == null);
}

test "literal strings: nesting and escapes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const o = try parseOne(arena.allocator(), "(a(b)c\\)\\n\\101\\0533\\\r\nd\re)");
    try testing.expectEqualStrings("a(b)c)\nA+3d\ne", o.string);
}

test "hex strings ignore whitespace and pad an odd digit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x2a, 0xf0 }, (try parseOne(arena.allocator(), "<00 2A f>")).string);
    try testing.expectError(error.Syntax, parseOne(arena.allocator(), "<0g>"));
}

test "names decode #xx" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("A B", (try parseOne(arena.allocator(), "/A#20B")).name);
    try testing.expectError(error.Syntax, parseOne(arena.allocator(), "/A#2"));
}

test "dictionaries, arrays and references" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const o = try parseOne(arena.allocator(), "<< /Kids [3 0 R 4 0 R] /Count 2 /MediaBox [0 0 595.28 841.89] /Open true /X null >>");
    const d = o.dict;
    const kids = d.get("Kids").?.array;
    try testing.expectEqual(@as(usize, 2), kids.len);
    try testing.expectEqual(Ref{ .num = 4, .gen = 0 }, kids[1].ref);
    try testing.expectEqual(@as(i64, 2), d.get("Count").?.integer);
    try testing.expectEqual(@as(f64, 841.89), d.get("MediaBox").?.array[3].number().?);
    try testing.expect(d.get("Open").?.boolean);
    try testing.expect(d.get("X").? == .null);
    try testing.expect(d.get("Missing") == null);
}

test "integers not followed by R stay integers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const items = (try parseOne(arena.allocator(), "[1 2 3 0 R 5]")).array;
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqual(@as(i64, 1), items[0].integer);
    try testing.expectEqual(@as(i64, 2), items[1].integer);
    try testing.expectEqual(Ref{ .num = 3, .gen = 0 }, items[2].ref);
    try testing.expectEqual(@as(i64, 5), items[3].integer);
}

test "nesting deeper than max_depth is rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var src: [2 * (max_depth + 2)]u8 = undefined;
    @memset(src[0 .. src.len / 2], '[');
    @memset(src[src.len / 2 ..], ']');
    try testing.expectError(error.TooDeep, parseOne(arena.allocator(), &src));
}

test "unterminated input is a syntax error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.Syntax, parseOne(arena.allocator(), "(abc"));
    try testing.expectError(error.Syntax, parseOne(arena.allocator(), "<< /A 1"));
    try testing.expectError(error.Syntax, parseOne(arena.allocator(), "<< 1 2 >>"));
}
