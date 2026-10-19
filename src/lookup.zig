//! Port of db.py: resolve accounts and securities by (partial) name,
//! prompting when several match.

const std = @import("std");
const App = @import("App.zig");
const f = @import("format.zig");

pub const Account = struct { id: i64, name: []const u8 };
pub const Security = struct { id: i64, isin: []const u8, name: []const u8 };

fn queryAccounts(app: *App, sql: []const u8, arg: ?[]const u8) ![]Account {
    var st = try app.db.prepare(sql);
    defer st.finalize();
    if (arg) |v| try st.bindAll(.{v});
    var list: std.ArrayList(Account) = .empty;
    while (try st.step()) try list.append(app.a, .{
        .id = st.int(0),
        .name = (try st.text(app.a, 1)) orelse "",
    });
    return list.items;
}

/// Accounts whose name contains `pattern` (SQL LIKE, case-insensitive ASCII).
pub fn accountsLike(app: *App, pattern: []const u8) ![]Account {
    return queryAccounts(app, "SELECT id, name FROM account WHERE name LIKE ?", try app.fmt("%{s}%", .{pattern}));
}

pub fn getOrPromptAccount(app: *App, account_name: ?[]const u8) !?Account {
    var results: []Account = undefined;
    if (account_name) |name| {
        const exact = try queryAccounts(app, "SELECT id, name FROM account WHERE name = ?", name);
        if (exact.len > 0) return exact[0];
        results = try accountsLike(app, name);
    } else {
        results = try queryAccounts(app, "SELECT id, name FROM account", null);
    }

    if (results.len == 0) {
        try app.print("{s}No accounts found. Create one with: dv account add <name>{s}\n", .{ f.RED, f.RESET });
        return null;
    }
    if (results.len == 1) return results[0];

    try app.line("Select an account:");
    for (results, 1..) |acc, i|
        try app.print("  {s}{s}{d}{s}: {s} (ID: {d})\n", .{ f.BOLD, f.GREEN, i, f.RESET, acc.name, acc.id });
    return pick(app, Account, results, "Account number: ");
}

pub fn getOrPromptSecurity(app: *App, identifier: []const u8) !?Security {
    var st = try app.db.prepare("SELECT id, isin, name FROM security WHERE name LIKE ? OR isin LIKE ?");
    defer st.finalize();
    const pat = try app.fmt("%{s}%", .{identifier});
    try st.bindAll(.{ pat, pat });
    var list: std.ArrayList(Security) = .empty;
    while (try st.step()) try list.append(app.a, .{
        .id = st.int(0),
        .isin = (try st.text(app.a, 1)) orelse "None",
        .name = (try st.text(app.a, 2)) orelse "None",
    });
    const results = list.items;

    if (results.len == 0) {
        try app.print("{s}No security found matching '{s}'.{s}\n", .{ f.RED, identifier, f.RESET });
        return null;
    }
    if (results.len == 1) return results[0];

    try app.print("Multiple securities match '{s}':\n", .{identifier});
    for (results, 1..) |sec, i|
        try app.print("  {s}{s}{d}{s}: {s} (ISIN: {s}, ID: {d})\n", .{ f.BOLD, f.GREEN, i, f.RESET, sec.name, sec.isin, sec.id });
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
