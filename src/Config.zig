const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const journal = @import("journal.zig");

const Config = @This();

pub const Paperless = struct {
    url: ?[]const u8 = null,
    keychain: ?[]const u8 = null,
};

/// The local model `dv import` falls back to.
pub const Ollama = struct {
    url: []const u8 = "http://localhost:11434",
    model: []const u8 = "mistral",
};

/// Account names for the double-entry ledger (docs/ledger-model.md).
pub const Ledger = struct {
    roots: journal.Roots = .{},
    /// Person owning broker accounts without an explicit `.owner`.
    owner: []const u8 = "Owner",
    /// Where shortcuts and parsers book.
    accounts: Accounts = .{},
    brokers: []const Broker = &.{},

    pub const Accounts = struct {
        fees: []const u8 = "Expenses:Fees",
        kapest: []const u8 = "Expenses:Tax:KapESt",
        soli: []const u8 = "Expenses:Tax:Soli",
        kist: []const u8 = "Expenses:Tax:KiSt",
        quellensteuer: []const u8 = "Expenses:Tax:Quellensteuer",
        dividends: []const u8 = "Income:Dividends",
        interest: []const u8 = "Income:Interest",
        gains_shares: []const u8 = "Income:Gains:Shares",
        gains_other: []const u8 = "Income:Gains:Other",
        vorabpauschale: []const u8 = "Income:Vorabpauschale",
        contributions: []const u8 = "Equity:Contributions",
    };

    pub const Broker = struct {
        /// The account name used by `dv add -a` and `dv import -a`.
        name: []const u8,
        owner: ?[]const u8 = null,
        cash: ?[]const u8 = null,
        depot: ?[]const u8 = null,
    };

    /// A broker's ledger accounts, `Assets:<name>:Cash`/`Depot` unless configured.
    pub fn broker(l: Ledger, a: Allocator, name: []const u8) Allocator.Error!Broker {
        for (l.brokers) |b| if (std.mem.eql(u8, b.name, name)) return .{
            .name = b.name,
            .owner = b.owner orelse l.owner,
            .cash = b.cash orelse try std.fmt.allocPrint(a, "{s}:{s}:Cash", .{ l.roots.assets, name }),
            .depot = b.depot orelse try std.fmt.allocPrint(a, "{s}:{s}:Depot", .{ l.roots.assets, name }),
        };
        return .{
            .name = name,
            .owner = l.owner,
            .cash = try std.fmt.allocPrint(a, "{s}:{s}:Cash", .{ l.roots.assets, name }),
            .depot = try std.fmt.allocPrint(a, "{s}:{s}:Depot", .{ l.roots.assets, name }),
        };
    }

    /// Configured names that do not sit under the root their role needs.
    pub fn misplaced(l: Ledger, a: Allocator) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        const want = [_]struct { []const u8, journal.Kind }{
            .{ l.accounts.fees, .expense },          .{ l.accounts.kapest, .expense },
            .{ l.accounts.soli, .expense },          .{ l.accounts.kist, .expense },
            .{ l.accounts.quellensteuer, .expense }, .{ l.accounts.dividends, .income },
            .{ l.accounts.interest, .income },       .{ l.accounts.gains_shares, .income },
            .{ l.accounts.gains_other, .income },    .{ l.accounts.vorabpauschale, .income },
            .{ l.accounts.contributions, .equity },
        };
        for (want) |w| if (journal.kindOf(w[0], l.roots) != w[1]) try out.append(a, w[0]);
        for (l.brokers) |b| {
            const full = try l.broker(a, b.name);
            for ([_][]const u8{ full.cash.?, full.depot.? }) |n|
                if (journal.kindOf(n, l.roots) != .asset) try out.append(a, n);
        }
        return out.items;
    }
};

const File = struct {
    db: []const u8 = "data.db",
    paperless: Paperless = .{},
    ollama: Ollama = .{},
    ledger: Ledger = .{},
};

path: ?[]const u8 = null,
found: bool = false,
db: []const u8 = (File{}).db,
paperless: Paperless = .{},
ollama: Ollama = .{},
ledger: Ledger = .{},
token: ?[]const u8 = null,

fn zonPath(a: Allocator, environ: *const std.process.Environ.Map) !?[]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |dir| if (dir.len > 0)
        return try std.fmt.allocPrint(a, "{s}/doddsville/config.zon", .{dir});
    const home = environ.get("HOME") orelse return null;
    return try std.fmt.allocPrint(a, "{s}/.config/doddsville/config.zon", .{home});
}

pub fn load(a: Allocator, io: Io, environ: *const std.process.Environ.Map) !Config {
    const path = (try zonPath(a, environ)) orelse return .{};
    const source = Io.Dir.cwd().readFileAllocOptions(io, path, a, .limited(64 * 1024), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return .{ .path = path },
        else => return err,
    };
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const file = std.zon.parse.fromSlice(File, .{
        .gpa = a,
        .arena = a,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| switch (err) {
        error.ParseZon => {
            std.debug.print("{f}", .{diagnostics.fmt(path)});
            return error.InvalidConfig;
        },
        else => return err,
    };
    if (file.paperless.keychain) |service| if (service.len == 0) {
        std.debug.print("{s}: .paperless.keychain must not be empty\n", .{path});
        return error.InvalidConfig;
    };
    return .{ .path = path, .found = true, .db = file.db, .paperless = file.paperless, .ollama = file.ollama, .ledger = file.ledger };
}

pub fn paperlessToken(c: *Config, a: Allocator, io: Io, environ: *const std.process.Environ.Map) error{ OutOfMemory, Keychain }!?[]const u8 {
    if (c.token) |t| return t;
    const service = c.paperless.keychain orelse return null;
    const token = keychainPassword(a, io, environ.get("HOME"), service, &token_buf) catch return error.Keychain;
    assert(token.len > 0 and token.len < token_buf.len);
    assert(token[token.len - 1] != '\n');
    c.token = token;
    return token;
}

var token_buf: [4096]u8 = undefined;

fn keychainPassword(a: Allocator, io: Io, home: ?[]const u8, service: []const u8, buf: []u8) ![]const u8 {
    assert(service.len > 0);
    assert(buf.len > 0);
    var env: std.process.Environ.Map = .init(a);
    if (home) |h| try env.put("HOME", h);
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/usr/bin/security", "find-generic-password", "-s", service, "-w" },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer child.kill(io);
    var reader = child.stdout.?.readerStreaming(io, &.{});
    const n = try reader.interface.readSliceShort(buf);
    assert(n <= buf.len);
    if (n == buf.len) return error.KeychainItemTooLong;
    const term = try child.wait(io);
    if (!term.success()) return error.KeychainItemNotFound;
    const token = std.mem.trimEnd(u8, buf[0..n], "\n");
    if (token.len == 0) return error.KeychainItemNotFound;
    return token;
}

test "config.zon" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const file = try std.zon.parse.fromSlice(File, .{
        .gpa = arena.allocator(),
        .arena = arena.allocator(),
        .source = ".{ .db = \"/tmp/x.db\", .paperless = .{ .url = \"http://nas:8000\", .keychain = \"dv\" } }",
        .diagnostics = &diagnostics,
    });
    try std.testing.expectEqualStrings("/tmp/x.db", file.db);
    try std.testing.expectEqualStrings("http://nas:8000", file.paperless.url.?);
    try std.testing.expectEqualStrings("dv", file.paperless.keychain.?);
    try std.testing.expectEqualStrings("http://localhost:11434", file.ollama.url);
    try std.testing.expectEqualStrings("mistral", file.ollama.model);

    const custom = try std.zon.parse.fromSlice(File, .{
        .gpa = arena.allocator(),
        .arena = arena.allocator(),
        .source = ".{ .ollama = .{ .model = \"llama3.2\" } }",
        .diagnostics = &diagnostics,
    });
    try std.testing.expectEqualStrings("llama3.2", custom.ollama.model);
    try std.testing.expectEqualStrings("http://localhost:11434", custom.ollama.url);
}

test "ledger accounts: defaults, brokers and misplaced names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const file = try std.zon.parse.fromSlice(File, .{
        .gpa = a,
        .arena = a,
        .source =
        \\.{ .ledger = .{
        \\    .owner = "Name",
        \\    .accounts = .{ .fees = "Expenses:Gebühren", .dividends = "Expenses:Oops" },
        \\    .brokers = .{ .{ .name = "Scalable", .cash = "Assets:Name:Scalable:Verrechnung" } },
        \\} }
        ,
        .diagnostics = &diagnostics,
    });
    const l = file.ledger;
    try std.testing.expectEqualStrings("Expenses:Gebühren", l.accounts.fees);
    try std.testing.expectEqualStrings("Income:Interest", l.accounts.interest);

    const s = try l.broker(a, "Scalable");
    try std.testing.expectEqualStrings("Name", s.owner.?);
    try std.testing.expectEqualStrings("Assets:Name:Scalable:Verrechnung", s.cash.?);
    try std.testing.expectEqualStrings("Assets:Scalable:Depot", s.depot.?);
    const other = try l.broker(a, "Trade Republic");
    try std.testing.expectEqualStrings("Assets:Trade Republic:Cash", other.cash.?);

    const bad = try l.misplaced(a);
    try std.testing.expectEqual(@as(usize, 1), bad.len);
    try std.testing.expectEqualStrings("Expenses:Oops", bad[0]);

    try std.testing.expectEqual(@as(usize, 0), (try (Ledger{}).misplaced(a)).len);
}
