//! Settings come from ~/.config/doddsville/config.zon. Without that file the
//! Python-era sources are used: ./dv.conf plus DV_PAPERLESS_URL / DV_PAPERLESS_TOKEN.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Config = @This();

pub const config_file = "dv.conf";
pub const default_db = "data.db";
pub const secret_keys = [_][]const u8{ "paperless_url", "paperless_token" };

pub const Entry = struct { key: []const u8, value: []const u8 };

/// Insertion-ordered, like the Python dict.
entries: std.ArrayList(Entry) = .empty,
/// Set when the settings were read from config.zon.
zon_path: ?[]const u8 = null,

pub const File = struct {
    db: ?[]const u8 = null,
    paperless: struct {
        url: ?[]const u8 = null,
        keychain: ?[]const u8 = null,
    } = .{},
};

fn zonPath(a: Allocator, environ: *const std.process.Environ.Map) !?[]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |dir| if (dir.len > 0)
        return try std.fmt.allocPrint(a, "{s}/doddsville/config.zon", .{dir});
    const home = environ.get("HOME") orelse return null;
    return try std.fmt.allocPrint(a, "{s}/.config/doddsville/config.zon", .{home});
}

fn loadZon(a: Allocator, io: Io, environ: *const std.process.Environ.Map) !?Config {
    const path = (try zonPath(a, environ)) orelse return null;
    const source = Io.Dir.cwd().readFileAllocOptions(io, path, a, .limited(64 * 1024), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return null,
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

    var c: Config = .{ .zon_path = path };
    try c.set(a, "db", file.db orelse default_db);
    if (file.paperless.url) |url| try c.set(a, "paperless_url", url);
    if (file.paperless.keychain) |service| {
        if (service.len == 0) return error.InvalidConfig;
        try c.set(a, "paperless_keychain", service);
    }
    if (environ.get("DV_PAPERLESS_TOKEN")) |v| if (v.len > 0) try c.set(a, "paperless_token", v);
    return c;
}

pub fn paperlessToken(c: *Config, a: Allocator, io: Io, environ: *const std.process.Environ.Map) error{ OutOfMemory, Keychain }!?[]const u8 {
    if (c.get("paperless_token")) |t| return t;
    const service = c.get("paperless_keychain") orelse return null;
    const token = keychainPassword(a, io, environ.get("HOME"), service, &token_buf) catch return error.Keychain;
    assert(token.len > 0 and token.len < token_buf.len);
    assert(token[token.len - 1] != '\n');
    try c.set(a, "paperless_token", token);
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

pub fn get(c: Config, key: []const u8) ?[]const u8 {
    for (c.entries.items) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
    return null;
}

pub fn set(c: *Config, a: Allocator, key: []const u8, value: []const u8) !void {
    for (c.entries.items) |*e| if (std.mem.eql(u8, e.key, key)) {
        e.value = value;
        return;
    };
    try c.entries.append(a, .{ .key = key, .value = value });
}

pub fn isSecret(key: []const u8) bool {
    for (secret_keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

pub fn load(a: Allocator, io: Io, environ: *const std.process.Environ.Map) !Config {
    if (try loadZon(a, io, environ)) |zon| return zon;
    var c: Config = .{};
    try c.set(a, "db", default_db);

    if (Io.Dir.cwd().readFileAlloc(io, config_file, a, .limited(1 << 20))) |data| {
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const l = std.mem.trim(u8, raw, " \t\r");
            if (l.len == 0 or l[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
            try c.set(a, std.mem.trim(u8, l[0..eq], " \t"), std.mem.trim(u8, l[eq + 1 ..], " \t"));
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    if (environ.get("DV_PAPERLESS_URL")) |v| if (v.len > 0) try c.set(a, "paperless_url", v);
    if (environ.get("DV_PAPERLESS_TOKEN")) |v| if (v.len > 0) try c.set(a, "paperless_token", v);
    return c;
}

/// Write non-secret keys back to dv.conf.
pub fn save(c: Config, a: Allocator, io: Io) !void {
    var buf: std.ArrayList(u8) = .empty;
    for (c.entries.items) |e| {
        if (isSecret(e.key)) continue;
        try buf.print(a, "{s}={s}\n", .{ e.key, e.value });
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = config_file, .data = buf.items });
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
    try std.testing.expectEqualStrings("/tmp/x.db", file.db.?);
    try std.testing.expectEqualStrings("http://nas:8000", file.paperless.url.?);
    try std.testing.expectEqualStrings("dv", file.paperless.keychain.?);
}
