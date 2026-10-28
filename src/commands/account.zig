//! `dv account`: the ledger accounts.

const App = @import("../App.zig");
const bookings = @import("../bookings.zig");
const journal = @import("../journal.zig");
const f = @import("../format.zig");
const ledger_cmd = @import("ledger.zig");

/// New accounts are only made on request; asset and liability accounts
/// belong to the configured owner.
pub fn add(app: *App, name: []const u8) !void {
    const b: bookings.Book = .{ .db = app.db, .a = app.a, .ledger = app.config.ledger };
    if (try journal.accountByName(app.db, name) != null) {
        try app.print("{s}Account '{s}' already exists.{s}\n", .{ f.RED, name, f.RESET });
        return;
    }
    _ = b.ensure(name, try b.person(app.config.ledger.owner)) catch |err| switch (err) {
        error.InvalidAccountName => {
            const r = app.config.ledger.roots;
            try app.print("{s}'{s}' must start with {s}, {s}, {s}, {s} or {s}, followed by ':'.{s}\n", .{ f.RED, name, r.assets, r.liabilities, r.equity, r.income, r.expenses, f.RESET });
            return;
        },
        else => return err,
    };
    try app.print("{s}Account '{s}' created.{s}\n", .{ f.GREEN, name, f.RESET });
}

pub fn list(app: *App) !void {
    try ledger_cmd.sync(app);
    var st = try app.db.prepare(
        \\SELECT a.name, a.kind, o.name FROM ledger_account a
        \\LEFT JOIN person o ON o.id = a.owner ORDER BY a.name
    );
    defer st.finalize();
    var any = false;
    while (try st.step()) {
        if (!any) try app.print("{s}Accounts:{s}\n", .{ f.BOLD, f.RESET });
        any = true;
        try app.print("  {s} {s} {s}\n", .{
            try f.left(app.a, st.textRef(0).?, 40),
            try f.left(app.a, st.textRef(1).?, 10),
            st.textRef(2) orelse "",
        });
    }
    if (!any) try app.line("No accounts found.");
}
