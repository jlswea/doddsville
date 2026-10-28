//! `dv ledger`: the double-entry journal.

const std = @import("std");
const App = @import("../App.zig");
const bookings = @import("../bookings.zig");
const beancount = @import("../beancount.zig");
const f = @import("../format.zig");
const ledger_migration = @import("../ledger_migration.zig");

/// Migrates inside one database transaction and keeps it only if every
/// must-match figure agrees (and it is not a dry run).
pub fn migrate(app: *App, dry_run: bool) !void {
    const b: bookings.Book = .{ .db = app.db, .a = app.a, .ledger = app.config.ledger };
    try app.db.exec("BEGIN");
    var done = false;
    defer if (!done) app.db.exec("ROLLBACK") catch {};

    const sum = try ledger_migration.migrate(b);
    const checks = try ledger_migration.compare(b);

    try app.print("{s}Ledger migration{s}{s}\n", .{ f.BOLD, if (dry_run) " (dry run, nothing written)" else "", f.RESET });
    try app.print("  {d} transaction(s) built from the old rows ({d} transfer pair(s)), {d} document link(s)\n", .{ sum.migrated, sum.paired, sum.documents });
    if (sum.dividend_costs_as_kapest > 0)
        try app.print("  {s}{d} dividend cost(s) booked as KapESt; the old rows do not say which tax it was.{s}\n", .{ f.YELLOW, sum.dividend_costs_as_kapest, f.RESET });

    try app.print("\n  {s} {s} {s}\n", .{ try f.left(app.a, "Check", 44), try f.right(app.a, "Old", 14), try f.right(app.a, "New", 14) });
    var failed: usize = 0;
    for (checks) |c| {
        const show = struct {
            fn v(a: std.mem.Allocator, x: i64, shares: bool) ![]const u8 {
                return if (shares) f.quantity(a, x) else f.cents(a, x);
            }
        }.v;
        const mark = if (!c.must_match) f.YELLOW ++ "≈ changes by method" ++ f.RESET else if (c.ok()) f.GREEN ++ "✓" ++ f.RESET else f.RED ++ "✗" ++ f.RESET;
        if (!c.ok()) failed += 1;
        try app.print("  {s} {s} {s}  {s}\n", .{
            try f.left(app.a, c.label, 44),
            try f.right(app.a, try show(app.a, c.old, c.shares), 14),
            try f.right(app.a, try show(app.a, c.new, c.shares), 14),
            mark,
        });
    }

    if (failed > 0) {
        try app.print("\n{s}{d} check(s) differ; nothing was written.{s}\n", .{ f.RED, failed, f.RESET });
        return error.Reported;
    }
    if (dry_run) return;
    try app.db.exec("COMMIT");
    done = true;
    try app.print("\n{s}Journal written.{s}\n", .{ f.GREEN, f.RESET });
}

pub fn exportBeancount(app: *App) !void {
    try beancount.write(app.db, app.a, app.config.ledger.roots, app.out);
}
