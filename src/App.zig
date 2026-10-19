//! Shared per-invocation context: allocator, I/O, terminal, config, database.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Config = @import("Config.zig");
const sqlite = @import("sqlite.zig");

const App = @This();

/// Arena for everything; the process is short-lived.
a: Allocator,
io: Io,
out: *Io.Writer,
in: *Io.Reader,
environ: *std.process.Environ.Map,
config: Config,
db: sqlite.Db = undefined,

pub fn print(app: *App, comptime fmt_str: []const u8, args: anytype) !void {
    try app.out.print(fmt_str, args);
}

pub fn line(app: *App, s: []const u8) !void {
    try app.out.writeAll(s);
    try app.out.writeByte('\n');
}

/// Like Python's input(): print the prompt, flush, read one line without the
/// trailing newline. EOF yields an empty string.
pub fn input(app: *App, prompt: []const u8) ![]const u8 {
    try app.out.writeAll(prompt);
    try app.out.flush();
    const got = app.in.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.InputTooLong,
        error.ReadFailed => return error.ReadFailed,
    };
    const l = got orelse return "";
    const trimmed = if (l.len > 0 and l[l.len - 1] == '\r') l[0 .. l.len - 1] else l;
    return app.a.dupe(u8, trimmed);
}

/// Python's int(input(...)) – returns null when not an integer.
pub fn inputInt(app: *App, prompt: []const u8) !?i64 {
    const s = @import("format.zig").strip(try app.input(prompt));
    return std.fmt.parseInt(i64, s, 10) catch null;
}

pub fn fmt(app: *App, comptime f: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(app.a, f, args);
}
