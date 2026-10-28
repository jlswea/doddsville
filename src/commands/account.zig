//! Port of commands/account_cmd.py.

const App = @import("../App.zig");
const f = @import("../format.zig");
const ledger_cmd = @import("ledger.zig");

pub fn add(app: *App, name: []const u8) !void {
    app.db.run("INSERT INTO account (name) VALUES (?)", .{name}) catch |err| switch (err) {
        error.Constraint => {
            try app.print("{s}Account '{s}' already exists.{s}\n", .{ f.RED, name, f.RESET });
            return;
        },
        else => return err,
    };
    try app.print("{s}Account '{s}' created.{s}\n", .{ f.GREEN, name, f.RESET });
}

pub fn list(app: *App) !void {
    try ledger_cmd.rebuild(app);
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
