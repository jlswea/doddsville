//! Port of config.py. Non-secret settings live in ./dv.conf (key=value lines);
//! Paperless URL/token come from DV_PAPERLESS_URL / DV_PAPERLESS_TOKEN.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Config = @This();

pub const config_file = "dv.conf";
pub const default_db = "data.db";
pub const secret_keys = [_][]const u8{ "paperless_url", "paperless_token" };

pub const Entry = struct { key: []const u8, value: []const u8 };

/// Insertion-ordered, like the Python dict.
entries: std.ArrayList(Entry) = .empty,

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
