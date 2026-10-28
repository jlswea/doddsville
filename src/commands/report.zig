//! `dv report`: figures summed from the journal. Balance and holdings are
//! positions at the `--to` date; the other reports sum what happened between
//! `--from` and `--to`.

const std = @import("std");
const App = @import("../App.zig");
const f = @import("../format.zig");
const sqlite = @import("../sqlite.zig");
const ledger_cmd = @import("ledger.zig");

pub const Kind = enum { summary, balance, cashflow, holdings, performance };

pub const Filter = struct {
    account: ?[]const u8 = null,
    /// ISO dates
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
};

/// Each transaction's cash account: its first asset or liability posting
/// without a security. Flows are reported per cash account.
const cash_of =
    \\WITH cash_of AS (
    \\  SELECT t.id AS txn, (SELECT p.account FROM posting p JOIN ledger_account a ON a.id = p.account
    \\     WHERE p.txn = t.id AND a.kind IN ('asset', 'liability') AND p.security IS NULL AND NOT p.fee
    \\     ORDER BY p.id LIMIT 1) AS account
    \\  FROM txn t WHERE {date_filter})
;

const Ctx = struct {
    app: *App,
    filter: Filter,

    /// Prepares `template` with {date_filter} and {account_filter} (on `a.name`)
    /// substituted and binds the dates, then the account pattern.
    fn query(c: Ctx, comptime template: []const u8) !sqlite.Stmt {
        const a = c.app.a;
        const date_filter = if (c.filter.from != null and c.filter.to != null)
            "t.date >= ? AND t.date <= ?"
        else if (c.filter.from != null) "t.date >= ?" else if (c.filter.to != null) "t.date <= ?" else "1=1";
        const s0 = try std.mem.replaceOwned(u8, a, template, "{cash_of}", cash_of);
        const s1 = try std.mem.replaceOwned(u8, a, s0, "{date_filter}", date_filter);
        const sql = try std.mem.replaceOwned(u8, a, s1, "{account_filter}", if (c.filter.account != null) "a.name LIKE ?" else "1=1");
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

    fn atEnd(c: Ctx) Ctx {
        return .{ .app = c.app, .filter = .{ .account = c.filter.account, .to = c.filter.to } };
    }
};

pub fn run(app: *App, kind: Kind, filter: Filter) !void {
    try ledger_cmd.sync(app);
    try roles(app);
    const c: Ctx = .{ .app = app, .filter = filter };
    switch (kind) {
        .balance => try balance(c.atEnd()),
        .cashflow => try cashflow(c),
        .holdings => try holdings(c.atEnd()),
        .performance => try performance(c),
        .summary => try summary(c),
    }
}

/// The configured account names by what reports use them for, as a temporary
/// table so the queries can join it.
fn roles(app: *App) !void {
    try app.db.exec(
        \\CREATE TEMP TABLE IF NOT EXISTS role (name TEXT PRIMARY KEY, role TEXT NOT NULL);
        \\DELETE FROM role;
    );
    const n = app.config.ledger.accounts;
    const pairs = [_][2][]const u8{
        .{ n.contributions, "contributions" }, .{ n.dividends, "dividends" },     .{ n.interest, "interest" },
        .{ n.fees, "fees" },                   .{ n.kapest, "tax" },              .{ n.soli, "tax" },
        .{ n.kist, "tax" },                    .{ n.quellensteuer, "tax" },       .{ n.gains_shares, "gains" },
        .{ n.gains_other, "gains" },           .{ n.vorabpauschale, "vorabpauschale" },
    };
    for (pairs) |p| try app.db.run("INSERT OR IGNORE INTO role (name, role) VALUES (?, ?)", .{ p[0], p[1] });
}

fn money(app: *App, v: i64, w: usize) ![]const u8 {
    return f.right(app.a, try f.cents(app.a, v), w);
}

fn balance(c: Ctx) !void {
    const app = c.app;
    var st = try c.query(
        \\SELECT a.name, COALESCE(SUM(p.amount), 0)
        \\FROM ledger_account a
        \\JOIN posting p ON p.account = a.id
        \\JOIN txn t ON t.id = p.txn
        \\WHERE a.kind IN ('asset', 'liability') AND {date_filter} AND {account_filter}
        \\GROUP BY a.id ORDER BY a.name
    );
    defer st.finalize();

    try app.print("\n{s}Account Balances:{s}\n", .{ f.BOLD, f.RESET });
    try app.line(f.rep("-", 50));
    var total: i64 = 0;
    while (try st.step()) {
        const bal = st.int(1);
        total += bal;
        try app.print("  {s} {s}\n", .{ try f.left(app.a, st.textRef(0).?, 30), try money(app, bal, 15) });
    }
    try app.line(f.rep("-", 50));
    try app.print("  {s} {s}\n", .{ try f.left(app.a, "TOTAL", 30), try money(app, total, 15) });
    try app.print("  {s}Depots at cost.{s}\n", .{ f.YELLOW, f.RESET });
}

const Flows = struct {
    deposits: i64 = 0,
    withdrawals: i64 = 0,
    dividends: i64 = 0,
    interest: i64 = 0,
    fees: i64 = 0,
    taxes: i64 = 0,

    const columns =
        \\  COALESCE(SUM(CASE WHEN r.role = 'contributions' AND p.amount < 0 THEN -p.amount ELSE 0 END), 0),
        \\  COALESCE(SUM(CASE WHEN r.role = 'contributions' AND p.amount > 0 THEN p.amount ELSE 0 END), 0),
        \\  COALESCE(SUM(CASE WHEN r.role = 'dividends' THEN -p.amount ELSE 0 END), 0),
        \\  COALESCE(SUM(CASE WHEN r.role = 'interest' THEN -p.amount ELSE 0 END), 0),
        \\  COALESCE(SUM(CASE WHEN p.fee OR r.role = 'fees' THEN p.amount ELSE 0 END), 0),
        \\  COALESCE(SUM(CASE WHEN r.role = 'tax' THEN p.amount ELSE 0 END), 0)
    ;

    fn read(st: *sqlite.Stmt, first: c_int) Flows {
        return .{
            .deposits = st.int(first),
            .withdrawals = st.int(first + 1),
            .dividends = st.int(first + 2),
            .interest = st.int(first + 3),
            .fees = st.int(first + 4),
            .taxes = st.int(first + 5),
        };
    }

    fn add(x: *Flows, y: Flows) void {
        inline for (@typeInfo(Flows).@"struct".field_names) |name| @field(x, name) += @field(y, name);
    }

    fn net(x: Flows) i64 {
        return x.deposits - x.withdrawals + x.dividends + x.interest - x.fees - x.taxes;
    }
};

fn cashflow(c: Ctx) !void {
    const app = c.app;
    var st = try c.query("{cash_of}\n" ++
        \\SELECT a.name,
    ++ Flows.columns ++
        \\
        \\FROM cash_of
        \\JOIN ledger_account a ON a.id = cash_of.account
        \\JOIN posting p ON p.txn = cash_of.txn
        \\JOIN ledger_account pa ON pa.id = p.account
        \\LEFT JOIN role r ON r.name = pa.name
        \\WHERE {account_filter}
        \\GROUP BY a.id ORDER BY a.name
    );
    defer st.finalize();

    try app.print("\n{s}Cash Flow Report:{s}\n", .{ f.BOLD, f.RESET });
    try app.print("{s} {s} {s} {s} {s} {s} {s} {s}\n", .{
        try f.left(app.a, "Account", 24),  try f.right(app.a, "Deposits", 12), try f.right(app.a, "Withdrawals", 12),
        try f.right(app.a, "Dividends", 12), try f.right(app.a, "Interest", 12), try f.right(app.a, "Fees", 12),
        try f.right(app.a, "Taxes", 12),   try f.right(app.a, "Net", 12),
    });
    try app.line(f.rep("-", 109));

    var totals: Flows = .{};
    while (try st.step()) {
        const v = Flows.read(&st, 1);
        totals.add(v);
        try cashflowRow(app, st.textRef(0).?, v);
    }
    try app.line(f.rep("-", 109));
    try cashflowRow(app, "TOTAL", totals);
}

fn cashflowRow(app: *App, name: []const u8, v: Flows) !void {
    try app.print("{s} {s} {s} {s} {s} {s} {s} {s}\n", .{
        try f.left(app.a, name, 24),   try money(app, v.deposits, 12), try money(app, v.withdrawals, 12), try money(app, v.dividends, 12),
        try money(app, v.interest, 12), try money(app, v.fees, 12),     try money(app, v.taxes, 12),       try money(app, v.net(), 12),
    });
}

/// Open lots: what was bought until the date, minus what was sold from them
/// until the date.
fn holdings(c: Ctx) !void {
    const app = c.app;
    var st = try c.query(
        \\SELECT a.name, s.name,
        \\  SUM(l.quantity - COALESCE((SELECT SUM(lc.quantity) FROM lot_close lc JOIN txn t ON t.id = lc.txn
        \\        WHERE lc.lot = l.id AND {date_filter}), 0)),
        \\  SUM(l.cost - COALESCE((SELECT SUM(lc.cost) FROM lot_close lc JOIN txn t ON t.id = lc.txn
        \\        WHERE lc.lot = l.id AND {date_filter}), 0))
        \\FROM lot l
        \\JOIN ledger_account a ON a.id = l.account
        \\JOIN security s ON s.id = l.security
        \\JOIN txn t ON t.id = l.txn
        \\WHERE {date_filter} AND {account_filter}
        \\GROUP BY a.id, s.id
        \\HAVING SUM(l.quantity - COALESCE((SELECT SUM(lc.quantity) FROM lot_close lc JOIN txn t ON t.id = lc.txn
        \\        WHERE lc.lot = l.id AND {date_filter}), 0)) > 0
        \\ORDER BY a.name, s.name
    );
    defer st.finalize();
    // {date_filter} appears four times, so the parameters repeat; bind by hand.
    try bindRepeated(c, &st, 4);

    var current: ?[]const u8 = null;
    var any = false;
    while (try st.step()) {
        if (!any) {
            try app.print("\n{s}Portfolio Holdings:{s}\n", .{ f.BOLD, f.RESET });
            try app.print("{s} {s} {s} {s} {s}\n", .{
                try f.left(app.a, "Account", 24),   try f.left(app.a, "Security", 25),    try f.right(app.a, "Shares", 10),
                try f.right(app.a, "Avg Cost", 12), try f.right(app.a, "Total Cost", 14),
            });
            try app.line(f.rep("-", 89));
            any = true;
        }
        const account = (try st.text(app.a, 0)).?;
        const security = (try st.text(app.a, 1)) orelse "None";
        const shares = st.int(2);
        const cost = st.int(3);
        if (current == null or !std.mem.eql(u8, current.?, account)) {
            if (current != null) try app.line("");
            current = account;
        }
        try app.print("{s} {s} {s} {s} {s}\n", .{
            try f.left(app.a, account, 24),                       try f.left(app.a, security, 25), try f.right(app.a, try f.quantity(app.a, shares), 10),
            try money(app, share(cost, f.quantity_scale, shares), 12), try money(app, cost, 14),
        });
    }
    if (!any) try app.line("\nNo holdings found.");
}

/// Binds the date parameters `times` times, then the account pattern.
fn bindRepeated(c: Ctx, st: *sqlite.Stmt, times: usize) !void {
    var i: c_int = 1;
    for (0..times) |_| {
        if (c.filter.from) |v| {
            try st.bindOne(i, v);
            i += 1;
        }
        if (c.filter.to) |v| {
            try st.bindOne(i, v);
            i += 1;
        }
    }
    if (c.filter.account) |v| try st.bindOne(i, try c.app.fmt("%{s}%", .{v}));
}

/// value × part / whole, floored, without intermediate overflow. Quantities
/// are millionths, so a per-share average would truncate to nothing.
fn share(value: i64, part: i64, whole: i64) i64 {
    if (whole <= 0) return 0;
    const q = @divFloor(@as(i128, value) * part, whole);
    return std.math.cast(i64, q) orelse if (q < 0) std.math.minInt(i64) else std.math.maxInt(i64);
}

/// Per security: trades and dividends in the period, and the gains of the
/// sales in it by FIFO, after sale fees.
fn performance(c: Ctx) !void {
    const app = c.app;
    var st = try c.query(
        \\SELECT s.name,
        \\  COALESCE(SUM(CASE WHEN p.quantity > 0 THEN p.quantity END), 0),
        \\  COALESCE(SUM(CASE WHEN p.quantity < 0 THEN -p.quantity END), 0),
        \\  COALESCE(SUM(CASE WHEN p.quantity > 0 OR (p.fee AND pa.kind = 'asset') THEN p.amount END), 0),
        \\  COALESCE(SUM(CASE WHEN p.quantity < 0 THEN (SELECT SUM(lc.proceeds) FROM lot_close lc
        \\     JOIN lot l ON l.id = lc.lot WHERE lc.txn = p.txn AND l.security = p.security) END), 0),
        \\  COALESCE(SUM(CASE WHEN p.quantity < 0 THEN (SELECT SUM(lc.proceeds - lc.cost) FROM lot_close lc
        \\     JOIN lot l ON l.id = lc.lot WHERE lc.txn = p.txn AND l.security = p.security) END), 0),
        \\  COALESCE(SUM(CASE WHEN r.role = 'dividends' THEN -p.amount END), 0)
        \\FROM posting p
        \\JOIN txn t ON t.id = p.txn
        \\JOIN security s ON s.id = p.security
        \\JOIN ledger_account pa ON pa.id = p.account
        \\LEFT JOIN role r ON r.name = pa.name
        \\JOIN ledger_account a ON a.id = (SELECT account FROM posting q WHERE q.txn = p.txn ORDER BY q.id LIMIT 1)
        \\WHERE {date_filter} AND {account_filter}
        \\GROUP BY s.id ORDER BY s.name
    );
    defer st.finalize();

    var any = false;
    var total_realized: i64 = 0;
    var total_dividends: i64 = 0;
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
        const gain = st.int(5);
        const dividends = st.int(6);
        total_realized += gain;
        total_dividends += dividends;
        try app.print("{s} {s} {s} {s} {s} {s} {s}\n", .{
            try f.left(app.a, security, 25), try f.right(app.a, try f.quantity(app.a, st.int(1)), 8), try f.right(app.a, try f.quantity(app.a, st.int(2)), 8),
            try money(app, st.int(3), 12),   try money(app, st.int(4), 12),                            try f.right(app.a, try f.centsColored(app.a, gain), 23),
            try money(app, dividends, 12),
        });
    }
    if (!any) {
        try app.line("\nNo investment transactions found.");
        return;
    }
    const totals = try flowTotals(c);
    try app.line(f.rep("-", 105));
    try app.print("\n  {s}Realized Gains/Losses:{s}  {s}\n", .{ f.BOLD, f.RESET, try f.centsColored(app.a, total_realized) });
    try app.print("  {s}Total Dividends:{s}        {s}\n", .{ f.BOLD, f.RESET, try f.cents(app.a, total_dividends) });
    try app.print("  {s}Total Fees:{s}             {s}\n", .{ f.BOLD, f.RESET, try f.cents(app.a, totals.fees) });
    try app.print("  {s}Taxes Withheld:{s}         {s}\n", .{ f.BOLD, f.RESET, try f.cents(app.a, totals.taxes) });
    try app.print("  {s}Net Return:{s}             {s}\n", .{ f.BOLD, f.RESET, try f.centsColored(app.a, total_realized + total_dividends) });
    try app.print("\n  {s}Sell values and gains are after sale fees; buy values include buy fees.{s}\n", .{ f.YELLOW, f.RESET });
    try app.print("  {s}Unrealized gains/losses need market prices (not yet implemented).{s}\n", .{ f.YELLOW, f.RESET });
}

fn flowTotals(c: Ctx) !Flows {
    var st = try c.query("{cash_of}\n" ++
        \\SELECT
    ++ Flows.columns ++
        \\
        \\FROM cash_of
        \\JOIN ledger_account a ON a.id = cash_of.account
        \\JOIN posting p ON p.txn = cash_of.txn
        \\JOIN ledger_account pa ON pa.id = p.account
        \\LEFT JOIN role r ON r.name = pa.name
        \\WHERE {account_filter}
    );
    defer st.finalize();
    return if (try st.step()) Flows.read(&st, 0) else .{};
}

fn summary(c: Ctx) !void {
    const app = c.app;
    const rule = f.rep("═", 63);
    try app.print("\n{s}{s}{s}\n", .{ f.BOLD, rule, f.RESET });
    try app.print("{s}                     INVESTMENT SUMMARY{s}\n", .{ f.BOLD, f.RESET });
    try app.print("{s}{s}{s}\n", .{ f.BOLD, rule, f.RESET });

    const flows = try flowTotals(c);

    var realized: i64 = 0;
    {
        var st = try c.query(
            \\SELECT COALESCE(SUM(lc.proceeds - lc.cost), 0)
            \\FROM lot_close lc
            \\JOIN lot l ON l.id = lc.lot
            \\JOIN ledger_account a ON a.id = l.account
            \\JOIN txn t ON t.id = lc.txn
            \\WHERE {date_filter} AND {account_filter}
        );
        defer st.finalize();
        if (try st.step()) realized = st.int(0);
    }

    var cash: i64 = 0;
    var at_cost: i64 = 0;
    {
        var st = try c.atEnd().query(
            \\SELECT COALESCE(SUM(CASE WHEN p.security IS NULL THEN p.amount END), 0),
            \\       COALESCE(SUM(CASE WHEN p.security IS NOT NULL THEN p.amount END), 0)
            \\FROM posting p
            \\JOIN ledger_account a ON a.id = p.account
            \\JOIN txn t ON t.id = p.txn
            \\WHERE a.kind IN ('asset', 'liability') AND {date_filter} AND {account_filter}
        );
        defer st.finalize();
        if (try st.step()) {
            cash = st.int(0);
            at_cost = st.int(1);
        }
    }

    try app.print("\n  {s}Cash Flow:{s}\n", .{ f.BOLD, f.RESET });
    try app.print("    Deposits:              {s}\n", .{try money(app, flows.deposits, 14)});
    try app.print("    Withdrawals:           {s}\n", .{try money(app, flows.withdrawals, 14)});
    try app.print("    Net Contributions:     {s}\n", .{try money(app, flows.deposits - flows.withdrawals, 14)});

    try app.print("\n  {s}Income:{s}\n", .{ f.BOLD, f.RESET });
    try app.print("    Dividends:             {s}\n", .{try money(app, flows.dividends, 14)});
    try app.print("    Interest:              {s}\n", .{try money(app, flows.interest, 14)});
    try app.print("    Total Income:          {s}\n", .{try money(app, flows.dividends + flows.interest, 14)});

    try app.print("\n  {s}Performance:{s}\n", .{ f.BOLD, f.RESET });
    try app.print("    Realized Gains/Losses: {s}\n", .{try f.right(app.a, try f.centsColored(app.a, realized), 23)});
    try app.print("    Unrealized G/L:        {s}{s}{s}\n", .{ f.YELLOW, try f.right(app.a, "(needs prices)", 14), f.RESET });

    try app.print("\n  {s}Current Position:{s}\n", .{ f.BOLD, f.RESET });
    try app.print("    Cash Balance:          {s}\n", .{try money(app, cash, 14)});
    try app.print("    Holdings (at cost):    {s}\n", .{try money(app, at_cost, 14)});
    try app.print("    Total Fees Paid:       {s}\n", .{try money(app, flows.fees, 14)});
    try app.print("    Taxes Withheld:        {s}\n", .{try money(app, flows.taxes, 14)});

    try app.print("\n  {s}Total Portfolio Value:     {s}{s}\n", .{ f.BOLD, try money(app, cash + at_cost, 14), f.RESET });
    try app.print("{s}{s}{s}\n\n", .{ f.BOLD, rule, f.RESET });
}

test "share keeps precision with millionths" {
    // 0.5 of 1.5 shares bought for 30.00 cost 10.00.
    try std.testing.expectEqual(@as(i64, 1000), share(3000, 500_000, 1_500_000));
    try std.testing.expectEqual(@as(i64, 0), share(3000, 1, 0));
}
