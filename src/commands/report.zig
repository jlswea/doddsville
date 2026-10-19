//! Port of commands/report_cmd.py. SQL is unchanged; only the glue is new.

const std = @import("std");
const App = @import("../App.zig");
const f = @import("../format.zig");
const sqlite = @import("../sqlite.zig");

pub const Kind = enum { summary, balance, cashflow, holdings, performance };

pub const Filter = struct {
    account: ?[]const u8 = null,
    /// ISO dates
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
};

const Ctx = struct {
    app: *App,
    date_filter: []const u8,
    account_filter: []const u8,
    filter: Filter,

    /// Prepare `sql` (with {date_filter}/{account_filter} substituted) and
    /// bind date params first, then the account param — same order as Python.
    fn query(c: Ctx, comptime template: []const u8) !sqlite.Stmt {
        const a = c.app.a;
        const s1 = try std.mem.replaceOwned(u8, a, template, "{date_filter}", c.date_filter);
        const sql = try std.mem.replaceOwned(u8, a, s1, "{account_filter}", c.account_filter);
        var st = try c.app.db.prepare(sql);
        errdefer st.finalize();
        var i: c_int = 1;
        if (c.filter.from) |v| {
            try st.bindOne(i, v);
            i += 1;
        }
        if (c.filter.to) |v| {
            try st.bindOne(i, v);
            i += 1;
        }
        if (c.filter.account) |v| try st.bindOne(i, try c.app.fmt("%{s}%", .{v}));
        return st;
    }
};

pub fn run(app: *App, kind: Kind, filter: Filter) !void {
    var date_filter: []const u8 = "1=1";
    if (filter.from != null and filter.to != null) {
        date_filter = "t.date >= ? AND t.date <= ?";
    } else if (filter.from != null) {
        date_filter = "t.date >= ?";
    } else if (filter.to != null) {
        date_filter = "t.date <= ?";
    }
    const c: Ctx = .{
        .app = app,
        .date_filter = date_filter,
        .account_filter = if (filter.account != null) "a.name LIKE ?" else "1=1",
        .filter = filter,
    };
    switch (kind) {
        .balance => try balance(c),
        .cashflow => try cashflow(c),
        .holdings => try holdings(c),
        .performance => try performance(c),
        .summary => try summary(c),
    }
}

fn money(app: *App, v: i64, w: usize) ![]const u8 {
    return f.right(app.a, try f.cents(app.a, v), w);
}

fn balance(c: Ctx) !void {
    const app = c.app;
    var st = try c.query(
        \\SELECT
        \\    a.name,
        \\    COALESCE(SUM(CASE
        \\        WHEN t.type = 'deposit' THEN t.total_value
        \\        WHEN t.type = 'withdrawal' THEN -t.total_value
        \\        WHEN t.type = 'interest' THEN t.total_value
        \\        WHEN t.type = 'dividend' THEN t.total_value
        \\        WHEN t.type = 'buy' THEN -t.total_value
        \\        WHEN t.type = 'sell' THEN t.total_value
        \\        WHEN t.type = 'transfer' THEN t.total_value
        \\        ELSE 0
        \\    END), 0) as cash_balance,
        \\    COALESCE(SUM(CASE WHEN t.cost IS NOT NULL THEN -t.cost ELSE 0 END), 0) as total_fees
        \\FROM account a
        \\LEFT JOIN "transaction" t ON a.id = t.account AND {date_filter}
        \\WHERE {account_filter}
        \\GROUP BY a.id, a.name
        \\ORDER BY a.name
    );
    defer st.finalize();

    try app.print("\n{s}Account Balances:{s}\n", .{ f.BOLD, f.RESET });
    try app.line(f.rep("-", 50));
    var total_balance: i64 = 0;
    var total_fees: i64 = 0;
    while (try st.step()) {
        const name = (try st.text(app.a, 0)) orelse "None";
        const bal = st.int(1);
        const fees = st.int(2);
        total_balance += bal;
        total_fees += fees;
        try app.print("  {s} {s}  (fees: {s})\n", .{ try f.left(app.a, name, 20), try money(app, bal + fees, 15), try f.cents(app.a, @intCast(@abs(fees))) });
    }
    try app.line(f.rep("-", 50));
    try app.print("  {s} {s}  (fees: {s})\n", .{ try f.left(app.a, "TOTAL", 20), try money(app, total_balance + total_fees, 15), try f.cents(app.a, @intCast(@abs(total_fees))) });
}

fn cashflow(c: Ctx) !void {
    const app = c.app;
    var st = try c.query(
        \\SELECT
        \\    a.name,
        \\    COALESCE(SUM(CASE WHEN t.type = 'deposit' THEN t.total_value ELSE 0 END), 0) as deposits,
        \\    COALESCE(SUM(CASE WHEN t.type = 'withdrawal' THEN t.total_value ELSE 0 END), 0) as withdrawals,
        \\    COALESCE(SUM(CASE WHEN t.type = 'dividend' THEN t.total_value ELSE 0 END), 0) as dividends,
        \\    COALESCE(SUM(CASE WHEN t.type = 'interest' THEN t.total_value ELSE 0 END), 0) as interest,
        \\    COALESCE(SUM(CASE WHEN t.cost IS NOT NULL THEN t.cost ELSE 0 END), 0) as fees
        \\FROM account a
        \\LEFT JOIN "transaction" t ON a.id = t.account AND {date_filter}
        \\WHERE {account_filter}
        \\GROUP BY a.id, a.name
        \\ORDER BY a.name
    );
    defer st.finalize();

    try app.print("\n{s}Cash Flow Report:{s}\n", .{ f.BOLD, f.RESET });
    try app.print("{s} {s} {s} {s} {s} {s} {s}\n", .{
        try f.left(app.a, "Account", 20), try f.right(app.a, "Deposits", 12), try f.right(app.a, "Withdrawals", 12),
        try f.right(app.a, "Dividends", 12), try f.right(app.a, "Interest", 12),  try f.right(app.a, "Fees", 12),
        try f.right(app.a, "Net", 12),
    });
    try app.line(f.rep("-", 92));

    var totals = @as([5]i64, @splat(0));
    while (try st.step()) {
        const name = (try st.text(app.a, 0)) orelse "None";
        var v: [5]i64 = undefined;
        for (&v, 0..) |*x, i| x.* = st.int(@intCast(i + 1));
        for (&totals, v) |*t, x| t.* += x;
        try cashflowRow(app, name, v);
    }
    try app.line(f.rep("-", 92));
    try cashflowRow(app, "TOTAL", totals);
}

fn cashflowRow(app: *App, name: []const u8, v: [5]i64) !void {
    const net = v[0] - v[1] + v[2] + v[3] - v[4];
    try app.print("{s} {s} {s} {s} {s} {s} {s}\n", .{
        try f.left(app.a, name, 20), try money(app, v[0], 12), try money(app, v[1], 12), try money(app, v[2], 12),
        try money(app, v[3], 12),    try money(app, v[4], 12), try money(app, net, 12),
    });
}

fn holdings(c: Ctx) !void {
    const app = c.app;
    var st = try c.query(
        \\SELECT
        \\    a.name as account,
        \\    s.name as security,
        \\    SUM(CASE WHEN t.type = 'buy' THEN t.quantity ELSE 0 END) as bought,
        \\    SUM(CASE WHEN t.type = 'sell' THEN t.quantity ELSE 0 END) as sold,
        \\    SUM(CASE WHEN t.type = 'buy' THEN t.total_value ELSE 0 END) as total_cost,
        \\    SUM(CASE WHEN t.type = 'sell' THEN t.total_value ELSE 0 END) as total_proceeds
        \\FROM "transaction" t
        \\JOIN account a ON t.account = a.id
        \\JOIN security s ON t.security = s.id
        \\WHERE t.type IN ('buy', 'sell') AND {date_filter} AND {account_filter}
        \\GROUP BY a.id, s.id
        \\HAVING (bought - sold) > 0
        \\ORDER BY a.name, s.name
    );
    defer st.finalize();

    var current: ?[]const u8 = null;
    var any = false;
    while (try st.step()) {
        if (!any) {
            try app.print("\n{s}Portfolio Holdings:{s}\n", .{ f.BOLD, f.RESET });
            try app.print("{s} {s} {s} {s} {s}\n", .{
                try f.left(app.a, "Account", 20), try f.left(app.a, "Security", 25), try f.right(app.a, "Shares", 8),
                try f.right(app.a, "Avg Cost", 12), try f.right(app.a, "Total Cost", 14),
            });
            try app.line(f.rep("-", 85));
            any = true;
        }
        const account = (try st.text(app.a, 0)) orelse "None";
        const security = (try st.text(app.a, 1)) orelse "None";
        const bought = st.int(2);
        const sold = st.int(3);
        const total_cost = st.int(4);
        const shares = bought - sold;
        if (shares <= 0) continue;
        const avg = if (bought > 0) @divFloor(total_cost, bought) else 0;
        if (current == null or !std.mem.eql(u8, current.?, account)) {
            if (current != null) try app.line("");
            current = account;
        }
        try app.print("{s} {s} {s} {s} {s}\n", .{
            try f.left(app.a, account, 20), try f.left(app.a, security, 25), try f.right(app.a, try f.int(app.a, shares), 8),
            try money(app, avg, 12),        try money(app, avg * shares, 14),
        });
    }
    if (!any) try app.line("\nNo holdings found.");
}

fn realized(bought: i64, sold: i64, buy_value: i64, sell_value: i64) i64 {
    if (bought > 0 and sold > 0) return sell_value - @divFloor(buy_value, bought) * sold;
    return 0;
}

fn performance(c: Ctx) !void {
    const app = c.app;
    var st = try c.query(
        \\SELECT
        \\    s.name as security,
        \\    SUM(CASE WHEN t.type = 'buy' THEN t.quantity ELSE 0 END) as total_bought,
        \\    SUM(CASE WHEN t.type = 'sell' THEN t.quantity ELSE 0 END) as total_sold,
        \\    SUM(CASE WHEN t.type = 'buy' THEN t.total_value ELSE 0 END) as buy_value,
        \\    SUM(CASE WHEN t.type = 'sell' THEN t.total_value ELSE 0 END) as sell_value,
        \\    SUM(CASE WHEN t.type = 'dividend' THEN t.total_value ELSE 0 END) as dividends,
        \\    SUM(COALESCE(t.cost, 0)) as fees
        \\FROM "transaction" t
        \\JOIN account a ON t.account = a.id
        \\JOIN security s ON t.security = s.id
        \\WHERE t.type IN ('buy', 'sell', 'dividend') AND {date_filter} AND {account_filter}
        \\GROUP BY s.id
        \\ORDER BY s.name
    );
    defer st.finalize();

    var any = false;
    var total_realized: i64 = 0;
    var total_dividends: i64 = 0;
    var total_fees: i64 = 0;
    while (try st.step()) {
        if (!any) {
            try app.print("\n{s}Investment Performance:{s}\n", .{ f.BOLD, f.RESET });
            try app.print("{s} {s} {s} {s} {s} {s} {s}\n", .{
                try f.left(app.a, "Security", 25), try f.right(app.a, "Bought", 8),        try f.right(app.a, "Sold", 8),
                try f.right(app.a, "Buy Value", 12), try f.right(app.a, "Sell Value", 12), try f.right(app.a, "Realized G/L", 14),
                try f.right(app.a, "Dividends", 12),
            });
            try app.line(f.rep("-", 105));
            any = true;
        }
        const security = (try st.text(app.a, 0)) orelse "None";
        const bought = st.int(1);
        const sold = st.int(2);
        const buy_value = st.int(3);
        const sell_value = st.int(4);
        const dividends = st.int(5);
        const fees = st.int(6);
        const gain = realized(bought, sold, buy_value, sell_value);
        total_realized += gain;
        total_dividends += dividends;
        total_fees += fees;
        try app.print("{s} {s} {s} {s} {s} {s} {s}\n", .{
            try f.left(app.a, security, 25),       try f.right(app.a, try f.int(app.a, bought), 8), try f.right(app.a, try f.int(app.a, sold), 8),
            try money(app, buy_value, 12),         try money(app, sell_value, 12),                  try f.right(app.a, try f.centsColored(app.a, gain), 23),
            try money(app, dividends, 12),
        });
    }
    if (!any) {
        try app.line("\nNo investment transactions found.");
        return;
    }
    try app.line(f.rep("-", 105));
    try app.print("\n  {s}Realized Gains/Losses:{s}  {s}\n", .{ f.BOLD, f.RESET, try f.centsColored(app.a, total_realized) });
    try app.print("  {s}Total Dividends:{s}        {s}\n", .{ f.BOLD, f.RESET, try f.cents(app.a, total_dividends) });
    try app.print("  {s}Total Fees:{s}             {s}\n", .{ f.BOLD, f.RESET, try f.cents(app.a, total_fees) });
    try app.print("  {s}Net Return:{s}             {s}\n", .{ f.BOLD, f.RESET, try f.centsColored(app.a, total_realized + total_dividends - total_fees) });
    try app.print("\n  {s}Note: Unrealized gains/losses require current market prices (not yet implemented){s}\n", .{ f.YELLOW, f.RESET });
}

fn summary(c: Ctx) !void {
    const app = c.app;
    const rule = f.rep("═", 63);
    try app.print("\n{s}{s}{s}\n", .{ f.BOLD, rule, f.RESET });
    try app.print("{s}                     INVESTMENT SUMMARY{s}\n", .{ f.BOLD, f.RESET });
    try app.print("{s}{s}{s}\n", .{ f.BOLD, rule, f.RESET });

    var cash_balance: i64 = 0;
    var total_fees: i64 = 0;
    {
        var st = try c.query(
            \\SELECT
            \\    COALESCE(SUM(CASE
            \\        WHEN t.type = 'deposit' THEN t.total_value
            \\        WHEN t.type = 'withdrawal' THEN -t.total_value
            \\        WHEN t.type = 'interest' THEN t.total_value
            \\        WHEN t.type = 'dividend' THEN t.total_value
            \\        WHEN t.type = 'buy' THEN -t.total_value
            \\        WHEN t.type = 'sell' THEN t.total_value
            \\        WHEN t.type = 'transfer' THEN t.total_value
            \\        ELSE 0
            \\    END), 0) as cash_balance,
            \\    COALESCE(SUM(CASE WHEN t.cost IS NOT NULL THEN t.cost ELSE 0 END), 0) as total_fees
            \\FROM account a
            \\LEFT JOIN "transaction" t ON a.id = t.account AND {date_filter}
            \\WHERE {account_filter}
        );
        defer st.finalize();
        if (try st.step()) {
            cash_balance = st.int(0);
            total_fees = st.int(1);
        }
    }

    var flows = @as([4]i64, @splat(0)); // deposits, withdrawals, dividends, interest
    {
        var st = try c.query(
            \\SELECT
            \\    COALESCE(SUM(CASE WHEN t.type = 'deposit' THEN t.total_value ELSE 0 END), 0) as deposits,
            \\    COALESCE(SUM(CASE WHEN t.type = 'withdrawal' THEN t.total_value ELSE 0 END), 0) as withdrawals,
            \\    COALESCE(SUM(CASE WHEN t.type = 'dividend' THEN t.total_value ELSE 0 END), 0) as dividends,
            \\    COALESCE(SUM(CASE WHEN t.type = 'interest' THEN t.total_value ELSE 0 END), 0) as interest
            \\FROM account a
            \\LEFT JOIN "transaction" t ON a.id = t.account AND {date_filter}
            \\WHERE {account_filter}
        );
        defer st.finalize();
        if (try st.step()) for (&flows, 0..) |*x, i| {
            x.* = st.int(@intCast(i));
        };
    }

    var holdings_at_cost: i64 = 0;
    {
        var st = try c.query(
            \\SELECT
            \\    SUM(CASE WHEN t.type = 'buy' THEN t.quantity ELSE -t.quantity END) as shares,
            \\    SUM(CASE WHEN t.type = 'buy' THEN t.total_value ELSE 0 END) as buy_total,
            \\    SUM(CASE WHEN t.type = 'buy' THEN t.quantity ELSE 0 END) as bought_qty
            \\FROM "transaction" t
            \\JOIN account a ON t.account = a.id
            \\WHERE t.type IN ('buy', 'sell') AND {date_filter} AND {account_filter}
        );
        defer st.finalize();
        if (try st.step()) {
            const total_shares = st.optInt(0) orelse 0;
            const buy_total = st.optInt(1) orelse 0;
            var bought_qty = st.optInt(2) orelse 1;
            if (bought_qty == 0) bought_qty = 1; // Python: `row[2] or 1`
            const avg = if (bought_qty > 0) @divFloor(buy_total, bought_qty) else 0;
            holdings_at_cost = if (total_shares > 0) avg * total_shares else 0;
        }
    }

    var realized_total: i64 = 0;
    {
        var st = try c.query(
            \\SELECT
            \\    s.id,
            \\    SUM(CASE WHEN t.type = 'buy' THEN t.quantity ELSE 0 END) as bought,
            \\    SUM(CASE WHEN t.type = 'sell' THEN t.quantity ELSE 0 END) as sold,
            \\    SUM(CASE WHEN t.type = 'buy' THEN t.total_value ELSE 0 END) as buy_value,
            \\    SUM(CASE WHEN t.type = 'sell' THEN t.total_value ELSE 0 END) as sell_value
            \\FROM "transaction" t
            \\JOIN account a ON t.account = a.id
            \\JOIN security s ON t.security = s.id
            \\WHERE t.type IN ('buy', 'sell') AND {date_filter} AND {account_filter}
            \\GROUP BY s.id
        );
        defer st.finalize();
        while (try st.step()) realized_total += realized(st.int(1), st.int(2), st.int(3), st.int(4));
    }

    const deposits = flows[0];
    const withdrawals = flows[1];
    const dividends = flows[2];
    const interest = flows[3];

    try app.print("\n  {s}Cash Flow:{s}\n", .{ f.BOLD, f.RESET });
    try app.print("    Deposits:              {s}\n", .{try money(app, deposits, 14)});
    try app.print("    Withdrawals:           {s}\n", .{try money(app, withdrawals, 14)});
    try app.print("    Net Contributions:     {s}\n", .{try money(app, deposits - withdrawals, 14)});

    try app.print("\n  {s}Income:{s}\n", .{ f.BOLD, f.RESET });
    try app.print("    Dividends:             {s}\n", .{try money(app, dividends, 14)});
    try app.print("    Interest:              {s}\n", .{try money(app, interest, 14)});
    try app.print("    Total Income:          {s}\n", .{try money(app, dividends + interest, 14)});

    try app.print("\n  {s}Performance:{s}\n", .{ f.BOLD, f.RESET });
    try app.print("    Realized Gains/Losses: {s}\n", .{try f.right(app.a, try f.centsColored(app.a, realized_total), 23)});
    try app.print("    Unrealized G/L:        {s}{s}{s}\n", .{ f.YELLOW, try f.right(app.a, "(needs prices)", 14), f.RESET });

    try app.print("\n  {s}Current Position:{s}\n", .{ f.BOLD, f.RESET });
    try app.print("    Cash Balance:          {s}\n", .{try money(app, cash_balance - total_fees, 14)});
    try app.print("    Holdings (at cost):    {s}\n", .{try money(app, holdings_at_cost, 14)});
    try app.print("    Total Fees Paid:       {s}\n", .{try money(app, total_fees, 14)});

    try app.print("\n  {s}Total Portfolio Value:     {s}{s}\n", .{ f.BOLD, try money(app, cash_balance - total_fees + holdings_at_cost, 14), f.RESET });
    try app.print("{s}{s}{s}\n\n", .{ f.BOLD, rule, f.RESET });
}
