//! A small argparse stand-in: positionals, `--long`/`-s` options with a value,
//! flags, and `nargs="+"` style multi-value options/positionals.
//! Options may appear anywhere after the sub-command, like argparse.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { value, flag, multi };

pub const Opt = struct {
    long: []const u8,
    short: ?u8 = null,
    dest: []const u8,
    kind: Kind = .value,
    required: bool = false,
    help: []const u8 = "",
    metavar: []const u8 = "",
};

pub const Pos = struct {
    name: []const u8,
    /// nargs="+" (only valid for the last positional)
    multi: bool = false,
    help: []const u8 = "",
};

pub const Spec = struct {
    prog: []const u8,
    help: []const u8 = "",
    positionals: []const Pos = &.{},
    options: []const Opt = &.{},
};

pub const Parsed = struct {
    pos: []const []const u8,
    opts: []const Value,

    pub const Value = struct { dest: []const u8, values: []const []const u8 };

    pub fn get(p: Parsed, dest: []const u8) ?[]const u8 {
        const vs = p.getAll(dest) orelse return null;
        return if (vs.len > 0) vs[vs.len - 1] else null;
    }

    pub fn getAll(p: Parsed, dest: []const u8) ?[]const []const u8 {
        // last occurrence wins, like argparse
        var i = p.opts.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, p.opts[i].dest, dest)) return p.opts[i].values;
        }
        return null;
    }

    pub fn flag(p: Parsed, dest: []const u8) bool {
        return p.getAll(dest) != null;
    }

    /// Trailing values of a multi positional.
    pub fn rest(p: Parsed, from: usize) []const []const u8 {
        return if (from < p.pos.len) p.pos[from..] else &.{};
    }
};

pub const Error = error{ Usage, HelpShown } || Allocator.Error;

/// Set when `parse` returns error.Usage.
pub var last_error: []const u8 = "";

fn looksNegativeNumber(s: []const u8) bool {
    if (s.len < 2 or s[0] != '-') return false;
    for (s[1..]) |ch| if (!std.ascii.isDigit(ch) and ch != '.') return false;
    return true;
}

fn isOption(s: []const u8) bool {
    return s.len > 1 and s[0] == '-' and !looksNegativeNumber(s);
}

fn fail(a: Allocator, comptime f: []const u8, args: anytype) Error {
    last_error = try std.fmt.allocPrint(a, f, args);
    return error.Usage;
}

pub fn parse(a: Allocator, spec: Spec, argv: []const []const u8) Error!Parsed {
    var pos: std.ArrayList([]const u8) = .empty;
    var opts: std.ArrayList(Parsed.Value) = .empty;
    var only_positionals = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (only_positionals or !isOption(arg)) {
            try pos.append(a, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            only_positionals = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return error.HelpShown;

        // Resolve the option, supporting --name=value and -xVALUE.
        var name = arg;
        var inline_value: ?[]const u8 = null;
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                name = arg[0..eq];
                inline_value = arg[eq + 1 ..];
            }
        } else if (arg.len > 2) {
            name = arg[0..2];
            inline_value = arg[2..];
        }
        const opt = find(spec, name) orelse return fail(a, "unrecognized arguments: {s}", .{arg});

        switch (opt.kind) {
            .flag => try opts.append(a, .{ .dest = opt.dest, .values = &.{} }),
            .value => {
                const v = inline_value orelse blk: {
                    if (i + 1 >= argv.len or isOption(argv[i + 1]))
                        return fail(a, "argument {s}: expected one argument", .{optLabel(opt)});
                    i += 1;
                    break :blk argv[i];
                };
                const vs = try a.alloc([]const u8, 1);
                vs[0] = v;
                try opts.append(a, .{ .dest = opt.dest, .values = vs });
            },
            .multi => {
                var vs: std.ArrayList([]const u8) = .empty;
                if (inline_value) |v| try vs.append(a, v);
                while (i + 1 < argv.len and !isOption(argv[i + 1])) {
                    i += 1;
                    try vs.append(a, argv[i]);
                }
                if (vs.items.len == 0)
                    return fail(a, "argument {s}: expected at least one argument", .{optLabel(opt)});
                try opts.append(a, .{ .dest = opt.dest, .values = vs.items });
            },
        }
    }

    // Positional count checks.
    const want = spec.positionals.len;
    const multi_last = want > 0 and spec.positionals[want - 1].multi;
    if (pos.items.len < want) {
        var missing: std.ArrayList(u8) = .empty;
        for (spec.positionals[pos.items.len..], 0..) |p, k| {
            if (k > 0) try missing.appendSlice(a, ", ");
            try missing.appendSlice(a, p.name);
        }
        return fail(a, "the following arguments are required: {s}", .{missing.items});
    }
    if (pos.items.len > want and !multi_last) {
        var extra: std.ArrayList(u8) = .empty;
        for (pos.items[want..], 0..) |p, k| {
            if (k > 0) try extra.append(a, ' ');
            try extra.appendSlice(a, p);
        }
        return fail(a, "unrecognized arguments: {s}", .{extra.items});
    }

    for (spec.options) |o| if (o.required) {
        var found = false;
        for (opts.items) |v| if (std.mem.eql(u8, v.dest, o.dest)) {
            found = true;
        };
        if (!found) return fail(a, "the following arguments are required: {s}", .{optLabel(o)});
    };

    return .{ .pos = pos.items, .opts = opts.items };
}

fn find(spec: Spec, name: []const u8) ?Opt {
    for (spec.options) |o| {
        if (std.mem.eql(u8, o.long, name)) return o;
        if (o.short) |s| if (name.len == 2 and name[0] == '-' and name[1] == s) return o;
    }
    return null;
}

fn optLabel(o: Opt) []const u8 {
    return o.long;
}

pub fn writeHelp(w: *std.Io.Writer, spec: Spec) !void {
    try w.print("usage: {s} [-h]", .{spec.prog});
    for (spec.options) |o| {
        const mv = if (o.metavar.len > 0) o.metavar else "VALUE";
        switch (o.kind) {
            .flag => try w.print(" [{s}]", .{o.long}),
            .value => if (o.required) try w.print(" {s} {s}", .{ o.long, mv }) else try w.print(" [{s} {s}]", .{ o.long, mv }),
            .multi => try w.print(" [{s} {s} ...]", .{ o.long, mv }),
        }
    }
    for (spec.positionals) |p| {
        if (p.multi) try w.print(" {s} [{s} ...]", .{ p.name, p.name }) else try w.print(" {s}", .{p.name});
    }
    try w.writeAll("\n");
    if (spec.help.len > 0) try w.print("\n{s}\n", .{spec.help});
    if (spec.positionals.len > 0) {
        try w.writeAll("\npositional arguments:\n");
        for (spec.positionals) |p| try w.print("  {s: <22}{s}\n", .{ p.name, p.help });
    }
    try w.writeAll("\noptions:\n  -h, --help            show this help message and exit\n");
    for (spec.options) |o| {
        var buf: [64]u8 = undefined;
        const label = if (o.short) |s|
            try std.fmt.bufPrint(&buf, "-{c}, {s}", .{ s, o.long })
        else
            o.long;
        try w.print("  {s: <22}{s}\n", .{ label, o.help });
    }
}

const testing = std.testing;

test "parse positionals and options in any order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec: Spec = .{
        .prog = "dv add buy",
        .positionals = &.{ .{ .name = "identifier" }, .{ .name = "quantity" }, .{ .name = "price" } },
        .options = &.{
            .{ .long = "--account", .short = 'a', .dest = "account" },
            .{ .long = "--doc", .short = 'd', .dest = "doc", .kind = .multi },
        },
    };
    const p = try parse(a, spec, &.{ "-a", "Broker", "Apple", "10", "-1.50", "--doc", "12", "./x.pdf" });
    try testing.expectEqualStrings("Broker", p.get("account").?);
    try testing.expectEqual(@as(usize, 2), p.getAll("doc").?.len);
    try testing.expectEqual(@as(usize, 3), p.pos.len);
    try testing.expectEqualStrings("-1.50", p.pos[2]); // negative numbers are values, not options

    // like argparse, a multi option swallows following values (incl. negative numbers)
    try testing.expectError(error.Usage, parse(a, spec, &.{ "Apple", "10", "--doc", "12", "-1.50" }));

    try testing.expectError(error.Usage, parse(a, spec, &.{"Apple"}));
    try testing.expectEqualStrings("the following arguments are required: quantity, price", last_error);
    try testing.expectError(error.Usage, parse(a, spec, &.{ "Apple", "1", "2.00", "--nope" }));

    const q = try parse(a, spec, &.{ "Apple", "1", "-2.00", "--account=Cash" });
    try testing.expectEqualStrings("-2.00", q.pos[2]);
    try testing.expectEqualStrings("Cash", q.get("account").?);
}
