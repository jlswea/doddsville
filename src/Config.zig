const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

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

const File = struct {
    db: []const u8 = "data.db",
    paperless: Paperless = .{},
    ollama: Ollama = .{},
};

path: ?[]const u8 = null,
found: bool = false,
db: []const u8 = (File{}).db,
paperless: Paperless = .{},
ollama: Ollama = .{},
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
    return .{ .path = path, .found = true, .db = file.db, .paperless = file.paperless, .ollama = file.ollama };
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
