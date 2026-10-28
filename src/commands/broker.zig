//! `dv broker`: the names `-a` refers to. Each maps to a cash and a depot
//! account (see `.ledger.brokers` in config.zon).

const App = @import("../App.zig");
const f = @import("../format.zig");

pub fn add(app: *App, name: []const u8) !void {
    app.db.run("INSERT INTO broker (name) VALUES (?)", .{name}) catch |err| switch (err) {
        error.Constraint => {
            try app.print("{s}Broker '{s}' already exists.{s}\n", .{ f.RED, name, f.RESET });
            return;
        },
        else => return err,
    };
    try app.print("{s}Broker '{s}' created.{s}\n", .{ f.GREEN, name, f.RESET });
}

pub fn list(app: *App) !void {
    var st = try app.db.prepare("SELECT name FROM broker ORDER BY name");
    defer st.finalize();
    var any = false;
    while (try st.step()) {
        if (!any) try app.print("{s}Brokers:{s}\n", .{ f.BOLD, f.RESET });
        any = true;
        const name = st.textRef(0).?;
        const accounts = try app.config.ledger.broker(app.a, name);
        try app.print("  {s} {s}, {s}\n", .{ try f.left(app.a, name, 20), accounts.cash.?, accounts.depot.? });
    }
    if (!any) try app.line("No brokers found.");
}
