//! dv — Doddsville CLI (Zig port of cli.py).

const std = @import("std");
const Io = std.Io;

const App = @import("App.zig");
const Config = @import("Config.zig");
const args = @import("args.zig");
const f = @import("format.zig");
const migrations = @import("migrations.zig");
const paperless = @import("paperless.zig");
const sqlite = @import("sqlite.zig");

const account_cmd = @import("commands/account.zig");
const add_cmd = @import("commands/add.zig");
const config_cmd = @import("commands/config.zig");
const doc_cmd = @import("commands/doc.zig");
const edit_cmd = @import("commands/edit.zig");
const list_cmd = @import("commands/list.zig");
const report_cmd = @import("commands/report.zig");

pub const version = "doddsville@0.1.0";

// ------------------------------------------------------------------ specs

const account_opt: args.Opt = .{ .long = "--account", .short = 'a', .dest = "account", .metavar = "ACCOUNT", .help = "Account name" };
const cost_opt: args.Opt = .{ .long = "--cost", .short = 'c', .dest = "cost", .metavar = "COST", .help = "Fees/costs in euros (e.g., 1.50)" };

/// add buy/sell/dividend/interest/deposit/withdrawal: `-d` is --doc (as in cli.py)
const add_common = [_]args.Opt{
    account_opt,
    .{ .long = "--date", .dest = "date", .metavar = "DATE", .help = "Transaction date (DD.MM.YYYY)" },
    cost_opt,
    .{ .long = "--doc", .short = 'd', .dest = "doc", .kind = .multi, .metavar = "DOC", .help = "Paperless document ID(s) or file path(s) to upload" },
};
/// add transfer: `-d` is --date (as in cli.py)
const transfer_opts = [_]args.Opt{
    .{ .long = "--from", .dest = "from_account", .required = true, .metavar = "FROM_ACCOUNT", .help = "Source account" },
    .{ .long = "--to", .dest = "to_account", .required = true, .metavar = "TO_ACCOUNT", .help = "Destination account" },
    .{ .long = "--date", .short = 'd', .dest = "date", .metavar = "DATE", .help = "Transaction date (DD.MM.YYYY)" },
    .{ .long = "--cost", .short = 'c', .dest = "cost", .metavar = "COST", .help = "Transfer fees (e.g., 0.50)" },
    .{ .long = "--doc", .dest = "doc", .kind = .multi, .metavar = "DOC", .help = "Paperless document ID(s) or file path(s) to upload" },
};
const report_opts = [_]args.Opt{
    .{ .long = "--account", .short = 'a', .dest = "account", .metavar = "ACCOUNT", .help = "Filter by account name" },
    .{ .long = "--from", .dest = "from_date", .metavar = "FROM_DATE", .help = "Start date (DD.MM.YYYY)" },
    .{ .long = "--to", .dest = "to_date", .metavar = "TO_DATE", .help = "End date (DD.MM.YYYY)" },
};

fn addSpec(kind: add_cmd.Kind) args.Spec {
    return switch (kind) {
        .buy => .{ .prog = "dv add buy", .help = "Record a stock purchase.", .options = &add_common, .positionals = &.{
            .{ .name = "identifier", .help = "Security name or ISIN" },
            .{ .name = "quantity", .help = "Number of shares bought" },
            .{ .name = "price", .help = "Price per share (e.g., 123.45)" },
        } },
        .sell => .{ .prog = "dv add sell", .help = "Record a stock sale.", .options = &add_common, .positionals = &.{
            .{ .name = "name", .help = "Company name" },
            .{ .name = "quantity", .help = "Number of shares sold" },
            .{ .name = "price", .help = "Price per share (e.g., 123.45)" },
        } },
        .dividend => .{ .prog = "dv add dividend", .help = "Record a dividend payment.", .options = &add_common, .positionals = &.{
            .{ .name = "name", .help = "Company name" },
            .{ .name = "amount", .help = "Total dividend amount (e.g., 50.00)" },
        } },
        .interest => .{ .prog = "dv add interest", .help = "Record interest on cash balance.", .options = &add_common, .positionals = &.{
            .{ .name = "amount", .help = "Interest amount (e.g., 10.00)" },
        } },
        .deposit => .{ .prog = "dv add deposit", .help = "Record a deposit/contribution.", .options = &add_common, .positionals = &.{
            .{ .name = "amount", .help = "Deposit amount (e.g., 1000.00)" },
        } },
        .withdrawal => .{ .prog = "dv add withdrawal", .help = "Record a withdrawal.", .options = &add_common, .positionals = &.{
            .{ .name = "amount", .help = "Withdrawal amount (e.g., 500.00)" },
        } },
        .transfer => .{ .prog = "dv add transfer", .help = "Record a transfer between accounts.", .options = &transfer_opts, .positionals = &.{
            .{ .name = "amount", .help = "Transfer amount (e.g., 500.00)" },
        } },
    };
}

const top_help =
    \\usage: dv [-h] [-v] [--db DB] {account,list,add,edit,report,doc,config} ...
    \\
    \\dv: Managing common stocks transactions
    \\
    \\commands:
    \\  account   Manage accounts (add, list)
    \\  list      List all recorded transactions
    \\  add       Add a new transaction (buy, sell, dividend, interest, deposit, withdrawal, transfer)
    \\  edit      Edit an existing transaction
    \\  report    Reports (summary, balance, cashflow, holdings, performance)
    \\  doc       Manage documents linked to transactions (add, edit)
    \\  config    Manage CLI configuration (show, set, check)
    \\
    \\  import, sensor: not ported yet; use the Python CLI (pixi run python cli.py ...)
    \\
    \\options:
    \\  -h, --help     show this help message and exit
    \\  -v, --version  show the installed version and exit
    \\  --db DB        Path to SQLite database file (overrides config)
    \\  --mem-stats    Print peak memory use to stderr when done
    \\
;

// ------------------------------------------------------------------- main

/// TigerStyle: all memory comes from this one static budget. Nothing is
/// allocated from the OS after startup; exceeding it is an error, not growth.
const memory_budget = 4 * 1024 * 1024;
var memory: [memory_budget]u8 = undefined;

const sqlite_heap_size = 4 * 1024 * 1024;
var sqlite_heap: [sqlite_heap_size]u8 align(8) = undefined;

pub fn main(init: std.process.Init.Minimal) !u8 {
    try sqlite.useHeap(&sqlite_heap);
    var fba: std.heap.FixedBufferAllocator = .init(&memory);
    const a = fba.allocator();

    // dv never uses async/concurrent Io, so the Io needs no allocator of its own.
    var threaded: Io.Threaded = .init(.failing, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var environ_map = try std.process.Environ.createMap(init.environ, a);
    const argv = try init.args.toSlice(a);

    var out_buf: [8192]u8 = undefined;
    var out_file: Io.File.Writer = .init(.stdout(), io, &out_buf);
    var in_buf: [4096]u8 = undefined;
    var in_file: Io.File.Reader = .initStreaming(.stdin(), io, &in_buf);

    var app: App = .{
        .a = a,
        .io = io,
        .out = &out_file.interface,
        .in = &in_file.interface,
        .environ = &environ_map,
        .config = undefined,
    };

    const code: u8 = dispatch(&app, argv[1..]) catch |err| switch (err) {
        error.Usage => blk: {
            app.out.flush() catch {};
            std.debug.print("{s}error: {s}\n", .{ usage_prog, args.last_error });
            break :blk 2;
        },
        error.HelpShown => 0,
        error.OutOfMemory => blk: {
            app.out.flush() catch {};
            std.debug.print("dv: error: memory budget of {d} MiB exhausted\n", .{memory_budget / (1024 * 1024)});
            break :blk 1;
        },
        error.Reported => 1,
        else => blk: {
            app.out.flush() catch {};
            std.debug.print("dv: error: {s}\n", .{@errorName(err)});
            break :blk 1;
        },
    };
    app.out.flush() catch {};
    if (mem_stats) std.debug.print("dv: memory peak {d} of {d} KiB, sqlite {d} of {d} KiB, largest response {d} of {d} KiB\n", .{
        kib(fba.end_index),              memory_budget / 1024,
        kib(sqlite.peakMemory()),        sqlite_heap_size / 1024,
        kib(paperless.largest_response), paperless.max_response_size / 1024,
    });
    return code;
}

fn kib(bytes: usize) usize {
    return std.math.divCeil(usize, bytes, 1024) catch unreachable;
}

var mem_stats = false;

/// Program name for argparse-style error lines ("dv add buy: error: ...").
var usage_prog: []const u8 = "dv: ";

fn usage(app: *App, prog: []const u8, comptime fmt: []const u8, fargs: anytype) error{ Usage, OutOfMemory } {
    usage_prog = std.fmt.allocPrint(app.a, "{s}: ", .{prog}) catch "dv: ";
    args.last_error = try std.fmt.allocPrint(app.a, fmt, fargs);
    return error.Usage;
}

fn parse(app: *App, spec: args.Spec, argv: []const []const u8) !args.Parsed {
    return args.parse(app.a, spec, argv) catch |err| switch (err) {
        error.Usage => {
            usage_prog = try app.fmt("{s}: ", .{spec.prog});
            return error.Usage;
        },
        error.HelpShown => {
            try args.writeHelp(app.out, spec);
            return error.HelpShown;
        },
        else => return err,
    };
}

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn dispatch(app: *App, argv_all: []const []const u8) !u8 {
    // Global options (before the command), like argparse's top-level parser.
    var db_flag: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv_all.len and argv_all[i].len > 0 and argv_all[i][0] == '-') : (i += 1) {
        const arg = argv_all[i];
        if (eql(arg, "-h") or eql(arg, "--help")) {
            try app.out.writeAll(top_help);
            return 0;
        } else if (eql(arg, "-v") or eql(arg, "--version")) {
            try app.line(version);
            return 0;
        } else if (eql(arg, "--db")) {
            i += 1;
            if (i >= argv_all.len) return usage(app, "dv", "argument --db: expected one argument", .{});
            db_flag = argv_all[i];
        } else if (std.mem.startsWith(u8, arg, "--db=")) {
            db_flag = arg["--db=".len..];
        } else if (eql(arg, "--mem-stats")) {
            mem_stats = true;
        } else return usage(app, "dv", "unrecognized arguments: {s}", .{arg});
    }
    if (i >= argv_all.len) return usage(app, "dv", "the following arguments are required: command", .{});
    const command = argv_all[i];
    const rest = argv_all[i + 1 ..];

    app.config = try Config.load(app.a, app.io, app.environ);

    // `config` works without a database.
    if (eql(command, "config")) return configCommand(app, rest);

    if (eql(command, "import") or eql(command, "sensor")) {
        try app.print("{s}'dv {s}' is not ported to Zig yet.{s} Use the Python CLI for now:\n  pixi run python cli.py {s} ...\n", .{ f.YELLOW, command, f.RESET, command });
        return 1;
    }

    const known = [_][]const u8{ "account", "list", "add", "edit", "report", "doc" };
    var is_known = false;
    for (known) |k| if (eql(k, command)) {
        is_known = true;
    };
    if (!is_known) return usage(app, "dv", "argument command: invalid choice: '{s}' (choose from account, list, add, edit, report, doc, config, import, sensor)", .{command});

    // Parse/validate arguments before touching the database (argparse order).
    const action = try parseCommand(app, command, rest);

    const db_path = db_flag orelse (app.config.get("db") orelse Config.default_db);
    app.db = try sqlite.Db.open(try app.a.dupeSentinel(u8, db_path, 0));
    defer app.db.close();
    try migrations.run(app.db);
    try app.db.exec("PRAGMA foreign_keys = ON;");

    try execute(app, action);
    return 0;
}

const Action = union(enum) {
    account_add: []const u8,
    account_list,
    list: struct { account: ?[]const u8, type: ?[]const u8 },
    add: struct { args: add_cmd.Args, date: ?f.Date },
    edit: i64,
    report: struct { kind: report_cmd.Kind, account: ?[]const u8, from: ?f.Date, to: ?f.Date },
    doc_add: struct { txn: i64, docs: []const []const u8 },
    doc_edit: i64,
};

fn subcommand(app: *App, prog: []const u8, rest: []const []const u8, comptime choices: []const []const u8) ![]const u8 {
    if (rest.len == 0) return usage(app, prog, "the following arguments are required: action", .{});
    const sub = rest[0];
    if (eql(sub, "-h") or eql(sub, "--help")) {
        try app.print("usage: {s} [-h] {{", .{prog});
        inline for (choices, 0..) |ch, k| try app.print("{s}{s}", .{ if (k > 0) "," else "", ch });
        try app.line("} ...");
        return error.HelpShown;
    }
    inline for (choices) |ch| if (eql(ch, sub)) return sub;
    var buf: std.ArrayList(u8) = .empty;
    inline for (choices, 0..) |ch, k| {
        if (k > 0) try buf.appendSlice(app.a, ", ");
        try buf.print(app.a, "'{s}'", .{ch});
    }
    return usage(app, prog, "argument action: invalid choice: '{s}' (choose from {s})", .{ sub, buf.items });
}

fn intArg(app: *App, prog: []const u8, name: []const u8, v: []const u8) !i64 {
    return std.fmt.parseInt(i64, f.strip(v), 10) catch usage(app, prog, "argument {s}: invalid int value: '{s}'", .{ name, v });
}

fn centsArg(app: *App, prog: []const u8, name: []const u8, v: []const u8) !i64 {
    var msg: []const u8 = "";
    return f.parseCents(app.a, v, &msg) catch |err| switch (err) {
        error.InvalidArgument => usage(app, prog, "argument {s}: {s}", .{ name, msg }),
        else => err,
    };
}

fn dateArg(app: *App, prog: []const u8, name: []const u8, v: ?[]const u8) !?f.Date {
    const s = v orelse return null;
    return f.parseGermanDate(s) catch usage(app, prog, "argument {s}: Invalid date format: '{s}'. Expected DD.MM.YYYY.", .{ name, s });
}

fn parseCommand(app: *App, command: []const u8, rest: []const []const u8) !Action {
    if (eql(command, "account")) {
        const sub = try subcommand(app, "dv account", rest, &.{ "add", "list" });
        if (eql(sub, "add")) {
            const p = try parse(app, .{ .prog = "dv account add", .help = "Add a new account", .positionals = &.{.{ .name = "name", .help = "Account name" }} }, rest[1..]);
            return .{ .account_add = p.pos[0] };
        }
        _ = try parse(app, .{ .prog = "dv account list", .help = "List all accounts" }, rest[1..]);
        return .account_list;
    }

    if (eql(command, "list")) {
        const p = try parse(app, .{ .prog = "dv list", .help = "List all recorded transactions.", .options = &.{
            .{ .long = "--account", .short = 'a', .dest = "account", .metavar = "ACCOUNT", .help = "Filter by account name" },
            .{ .long = "--type", .short = 't', .dest = "type", .metavar = "TYPE", .help = "Filter by transaction type" },
        } }, rest);
        return .{ .list = .{ .account = p.get("account"), .type = p.get("type") } };
    }

    if (eql(command, "add")) {
        const sub = try subcommand(app, "dv add", rest, &.{ "buy", "sell", "dividend", "interest", "deposit", "withdrawal", "transfer" });
        const kind = std.meta.stringToEnum(add_cmd.Kind, sub).?;
        const spec = addSpec(kind);
        const p = try parse(app, spec, rest[1..]);
        var a: add_cmd.Args = .{ .kind = kind, .date = "" };
        switch (kind) {
            .buy, .sell => {
                a.security = p.pos[0];
                a.quantity = try intArg(app, spec.prog, "quantity", p.pos[1]);
                a.amount = try centsArg(app, spec.prog, "price", p.pos[2]);
            },
            .dividend => {
                a.security = p.pos[0];
                a.amount = try centsArg(app, spec.prog, "amount", p.pos[1]);
            },
            else => a.amount = try centsArg(app, spec.prog, "amount", p.pos[0]),
        }
        if (p.get("cost")) |c| a.cost = try centsArg(app, spec.prog, "--cost/-c", c);
        a.account = p.get("account");
        a.docs = p.getAll("doc");
        if (kind == .transfer) {
            a.from_account = p.get("from_account").?;
            a.to_account = p.get("to_account").?;
        }
        const date = try dateArg(app, spec.prog, if (kind == .transfer) "--date/-d" else "--date", p.get("date"));
        return .{ .add = .{ .args = a, .date = date } };
    }

    if (eql(command, "edit")) {
        const p = try parse(app, .{ .prog = "dv edit", .help = "Edit an existing transaction.", .positionals = &.{.{ .name = "transaction_id", .help = "Transaction ID to edit" }} }, rest);
        return .{ .edit = try intArg(app, "dv edit", "transaction_id", p.pos[0]) };
    }

    if (eql(command, "report")) {
        const sub = try subcommand(app, "dv report", rest, &.{ "summary", "balance", "cashflow", "holdings", "performance" });
        const prog = try app.fmt("dv report {s}", .{sub});
        const p = try parse(app, .{ .prog = prog, .options = &report_opts }, rest[1..]);
        return .{ .report = .{
            .kind = std.meta.stringToEnum(report_cmd.Kind, sub).?,
            .account = p.get("account"),
            .from = try dateArg(app, prog, "--from", p.get("from_date")),
            .to = try dateArg(app, prog, "--to", p.get("to_date")),
        } };
    }

    if (eql(command, "doc")) {
        const sub = try subcommand(app, "dv doc", rest, &.{ "add", "edit" });
        if (eql(sub, "add")) {
            const p = try parse(app, .{ .prog = "dv doc add", .help = "Link paperless document(s) to a transaction", .positionals = &.{
                .{ .name = "transaction_id", .help = "Transaction ID to link documents to" },
                .{ .name = "docs", .multi = true, .help = "Paperless document ID(s) or file path(s) to upload" },
            } }, rest[1..]);
            return .{ .doc_add = .{ .txn = try intArg(app, "dv doc add", "transaction_id", p.pos[0]), .docs = p.rest(1) } };
        }
        const p = try parse(app, .{ .prog = "dv doc edit", .help = "Edit metadata of a Paperless document", .positionals = &.{.{ .name = "doc_id", .help = "Paperless document ID to edit" }} }, rest[1..]);
        return .{ .doc_edit = try intArg(app, "dv doc edit", "doc_id", p.pos[0]) };
    }
    unreachable;
}

fn today(app: *App) ![]const u8 {
    var st = try app.db.prepare("SELECT date('now', 'localtime')");
    defer st.finalize();
    _ = try st.step();
    return (try st.text(app.a, 0)).?;
}

fn execute(app: *App, action: Action) !void {
    switch (action) {
        .account_add => |name| try account_cmd.add(app, name),
        .account_list => try account_cmd.list(app),
        .list => |l| try list_cmd.run(app, l.account, l.type),
        .add => |ad| {
            var a = ad.args;
            a.date = if (ad.date) |d| try d.iso(app.a) else try today(app);
            try add_cmd.run(app, a);
        },
        .edit => |id| try edit_cmd.run(app, id),
        .report => |r| try report_cmd.run(app, r.kind, .{
            .account = r.account,
            .from = if (r.from) |d| try d.iso(app.a) else null,
            .to = if (r.to) |d| try d.iso(app.a) else null,
        }),
        .doc_add => |d| try doc_cmd.add(app, d.txn, d.docs),
        .doc_edit => |id| try doc_cmd.edit(app, id),
    }
}

fn configCommand(app: *App, rest: []const []const u8) !u8 {
    const sub = try subcommand(app, "dv config", rest, &.{ "show", "set", "check" });
    if (eql(sub, "show")) {
        _ = try parse(app, .{ .prog = "dv config show", .help = "Show current configuration" }, rest[1..]);
        try config_cmd.show(app);
    } else if (eql(sub, "set")) {
        const p = try parse(app, .{ .prog = "dv config set", .help = "Set a configuration value", .positionals = &.{
            .{ .name = "key", .help = "Config key (e.g., db)" },
            .{ .name = "value", .help = "Config value" },
        } }, rest[1..]);
        try config_cmd.set(app, p.pos[0], p.pos[1]);
    } else {
        _ = try parse(app, .{ .prog = "dv config check", .help = "Check paperless-ngx API connection" }, rest[1..]);
        try config_cmd.check(app);
    }
    return 0;
}

test {
    _ = @import("sqlite.zig");
    _ = @import("format.zig");
    _ = @import("args.zig");
    _ = @import("migrations.zig");
    _ = @import("lookup.zig");
}
