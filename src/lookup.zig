//! Port of db.py: resolve accounts and securities by (partial) name,
//! prompting when several match.

const std = @import("std");
const App = @import("App.zig");
const f = @import("format.zig");

pub const name_max = 128;
pub const max_matches = 32;

pub fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = undefined,
        len: std.math.IntFittingRange(0, capacity) = 0,

        const Self = @This();

        pub fn init(s: []const u8) error{TextTooLong}!Self {
            if (s.len > capacity) return error.TextTooLong;
            var t: Self = .{ .len = @intCast(s.len) };
            @memcpy(t.bytes[0..s.len], s);
            return t;
        }

        pub fn slice(t: *const Self) []const u8 {
            return t.bytes[0..t.len];
        }
    };
}

pub const Name = Text(name_max);
pub const Account = struct { id: i64, name: Name };
pub const Security = struct { id: i64, isin: Name, name: Name };

// One row more than max_matches is fetched to detect overflow.
const limit = std.fmt.comptimePrint(" LIMIT {d}", .{max_matches + 1});

fn queryAccounts(app: *App, comptime sql: []const u8, arg: ?[]const u8, buf: *[max_matches + 1]Account) ![]Account {
    var st = try app.db.prepare(sql ++ limit);
    defer st.finalize();
    if (arg) |v| try st.bindAll(.{v});
    var n: usize = 0;
    while (try st.step()) : (n += 1) buf[n] = .{
        .id = st.int(0),
        .name = try Name.init(st.textRef(1) orelse ""),
    };
    return buf[0..n];
}

/// Accounts whose name contains `pattern` (SQL LIKE, case-insensitive ASCII).
pub fn accountsLike(app: *App, pattern: []const u8, buf: *[max_matches + 1]Account) ![]Account {
    var pat_buf: [name_max + 2]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "%{s}%", .{pattern}) catch return error.TextTooLong;
    return queryAccounts(app, "SELECT id, name FROM account WHERE name LIKE ?", pat, buf);
}

fn tooMany(app: *App, what: []const u8, pattern: []const u8) !void {
    try app.print("{s}More than {d} {s} match '{s}'; be more specific.{s}\n", .{ f.RED, max_matches, what, pattern, f.RESET });
}

pub fn getOrPromptAccount(app: *App, account_name: ?[]const u8) !?Account {
    var buf: [max_matches + 1]Account = undefined;
    var results: []Account = undefined;
    if (account_name) |name| {
        const exact = try queryAccounts(app, "SELECT id, name FROM account WHERE name = ?", name, &buf);
        if (exact.len > 0) return exact[0];
        results = try accountsLike(app, name, &buf);
    } else {
        results = try queryAccounts(app, "SELECT id, name FROM account", null, &buf);
    }

    if (results.len == 0) {
        try app.print("{s}No accounts found. Create one with: dv account add <name>{s}\n", .{ f.RED, f.RESET });
        return null;
    }
    if (results.len > max_matches) {
        try tooMany(app, "accounts", account_name orelse "");
        return null;
    }
    if (results.len == 1) return results[0];

    try app.line("Select an account:");
    for (results, 1..) |*acc, i|
        try app.print("  {s}{s}{d}{s}: {s} (ID: {d})\n", .{ f.BOLD, f.GREEN, i, f.RESET, acc.name.slice(), acc.id });
    return pick(app, Account, results, "Account number: ");
}

pub fn getOrPromptSecurity(app: *App, identifier: []const u8) !?Security {
    var st = try app.db.prepare("SELECT id, isin, name FROM security WHERE name LIKE ? OR isin LIKE ?" ++ limit);
    defer st.finalize();
    var pat_buf: [name_max + 2]u8 = undefined;
    const pat = std.fmt.bufPrint(&pat_buf, "%{s}%", .{identifier}) catch return error.TextTooLong;
    try st.bindAll(.{ pat, pat });
    var buf: [max_matches + 1]Security = undefined;
    var n: usize = 0;
    while (try st.step()) : (n += 1) buf[n] = .{
        .id = st.int(0),
        .isin = try Name.init(st.textRef(1) orelse "None"),
        .name = try Name.init(st.textRef(2) orelse "None"),
    };
    const results = buf[0..n];

    if (results.len == 0) {
        try app.print("{s}No security found matching '{s}'.{s}\n", .{ f.RED, identifier, f.RESET });
        return null;
    }
    if (results.len > max_matches) {
        try tooMany(app, "securities", identifier);
        return null;
    }
    if (results.len == 1) return results[0];

    try app.print("Multiple securities match '{s}':\n", .{identifier});
    for (results, 1..) |*sec, i|
        try app.print("  {s}{s}{d}{s}: {s} (ISIN: {s}, ID: {d})\n", .{ f.BOLD, f.GREEN, i, f.RESET, sec.name.slice(), sec.isin.slice(), sec.id });
    return pick(app, Security, results, "Which one? ");
}

/// int(input(prompt)) then results[option - 1], Python semantics included
/// (0 picks the last entry, like results[-1]).
pub fn pick(app: *App, comptime T: type, results: []const T, prompt: []const u8) !?T {
    if (try app.inputInt(prompt)) |n| {
        const len: i64 = @intCast(results.len);
        const idx = n - 1;
        if (idx >= 0 and idx < len) return results[@intCast(idx)];
        if (idx < 0 and idx >= -len) return results[@intCast(len + idx)];
    }
    try app.print("{s}Invalid selection.{s}\n", .{ f.RED, f.RESET });
    return null;
}

test "Text" {
    const t = try Text(4).init("abcd");
    try std.testing.expectEqualStrings("abcd", t.slice());
    try std.testing.expectError(error.TextTooLong, Text(4).init("abcde"));
}
