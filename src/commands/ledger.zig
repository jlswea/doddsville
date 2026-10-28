//! `dv ledger`: the double-entry journal.

const App = @import("../App.zig");
const beancount = @import("../beancount.zig");

pub fn exportBeancount(app: *App) !void {
    try beancount.write(app.db, app.a, app.config.ledger.roots, app.out);
}
