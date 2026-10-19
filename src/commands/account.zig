//! Port of commands/account_cmd.py.

const App = @import("../App.zig");
const f = @import("../format.zig");

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
    var st = try app.db.prepare("SELECT id, name FROM account ORDER BY name");
    defer st.finalize();
    var any = false;
    while (try st.step()) {
        if (!any) try app.print("{s}Accounts:{s}\n", .{ f.BOLD, f.RESET });
        any = true;
        try app.print("  {d}: {s}\n", .{ st.int(0), (try st.text(app.a, 1)) orelse "" });
    }
    if (!any) try app.line("No accounts found.");
}
