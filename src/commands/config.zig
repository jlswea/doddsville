//! Port of commands/config_cmd.py.

const std = @import("std");
const Io = std.Io;
const App = @import("../App.zig");
const Config = @import("../Config.zig");
const f = @import("../format.zig");
const paperless = @import("../paperless.zig");

pub fn show(app: *App) !void {
    try app.print("{s}Configuration:{s}\n", .{ f.BOLD, f.RESET });
    try app.print("  Config file: {s}\n", .{app.config.zon_path orelse Config.config_file});
    for (app.config.entries.items) |e| {
        if (std.mem.eql(u8, e.key, "paperless_token"))
            try app.print("  {s}: (configured)\n", .{e.key})
        else
            try app.print("  {s}: {s}\n", .{ e.key, e.value });
    }
    const no_url = app.config.get("paperless_url") == null;
    const no_token = app.config.get("paperless_token") == null and app.config.get("paperless_keychain") == null;
    if (no_url or no_token) {
        try app.print("\n  {s}Not set: {s}{s}{s}{s}\n", .{
            f.YELLOW,
            if (no_url) "DV_PAPERLESS_URL" else "",
            if (no_url and no_token) ", " else "",
            if (no_token) "DV_PAPERLESS_TOKEN" else "",
            f.RESET,
        });
        try app.line("  Set via environment variables (e.g. direnv)");
    }
}

pub fn set(app: *App, key: []const u8, value: []const u8) !void {
    if (app.config.zon_path) |path| {
        try app.print("{s}Settings come from {s}; edit that file instead.{s}\n", .{ f.YELLOW, path, f.RESET });
        return;
    }
    if (Config.isSecret(key)) {
        const env_var = try app.fmt("DV_{s}", .{try std.ascii.allocUpperString(app.a, key)});
        try app.print("{s}{s} should be set via environment variable {s}{s}\n", .{ f.YELLOW, key, env_var, f.RESET });
        try app.print("  export {s}={s}\n", .{ env_var, value });
        return;
    }
    try app.config.set(app.a, key, value);
    try app.config.save(app.a, app.io);
    try app.print("{s}Set {s}={s}{s}\n", .{ f.GREEN, key, value, f.RESET });
}

pub fn check(app: *App) !void {
    try app.print("{s}Checking paperless-ngx connection...{s}\n\n", .{ f.BOLD, f.RESET });
    const url = app.config.get("paperless_url");
    var keychain_failed = false;
    const token = app.config.paperlessToken(app.a, app.io, app.environ) catch |err| switch (err) {
        error.Keychain => blk: {
            keychain_failed = true;
            break :blk null;
        },
        else => |e| return e,
    };
    const ok_mark = f.GREEN ++ "✓" ++ f.RESET;
    const bad_mark = f.RED ++ "✗" ++ f.RESET;
    try app.print("  {s} paperless_url: {s}\n", .{ if (url != null) ok_mark else bad_mark, url orelse "(not set)" });
    try app.print("  {s} paperless_token: {s}\n", .{ if (token != null) ok_mark else bad_mark, if (token != null) "(configured)" else "(not set)" });

    var message: []const u8 = undefined;
    var success = false;
    var response_ms: ?i64 = null;
    var doc_count: ?[]const u8 = null;

    if (url == null) {
        message = "paperless_url not configured";
    } else if (keychain_failed) {
        message = paperless.initMessage(error.Keychain);
    } else if (token == null) {
        message = "paperless_token not configured";
    } else {
        var cl = try paperless.Client.init(app);
        defer cl.deinit();
        const start = Io.Timestamp.now(app.io, .awake);
        if (cl.request(.GET, "/api/", null, null)) |r| {
            const elapsed = start.durationTo(Io.Timestamp.now(app.io, .awake));
            response_ms = @intCast(@divTrunc(elapsed.toNanoseconds(), std.time.ns_per_ms));
            switch (r.status) {
                .ok => {
                    success = true;
                    message = "Connection successful";
                    if (cl.request(.GET, "/api/documents/", null, null)) |d| {
                        if (d.status == .ok) {
                            const v = std.json.parseFromSliceLeaky(std.json.Value, app.a, d.body, .{}) catch null;
                            doc_count = "unknown";
                            if (v) |val| if (paperless.field(val, "count")) |cv| switch (cv) {
                                .integer => |n| doc_count = try app.fmt("{d}", .{n}),
                                else => {},
                            };
                        }
                    } else |_| {}
                },
                .unauthorized => message = "Authentication failed - check your token",
                .forbidden => message = "Access forbidden - check token permissions",
                else => message = try app.fmt("Unexpected status code: {d}", .{@intFromEnum(r.status)}),
            }
        } else |err| {
            message = cl.describe(err);
        }
    }

    if (success) {
        try app.print("\n  {s}✓ {s}{s}\n", .{ f.GREEN, message, f.RESET });
        if (response_ms) |ms| try app.print("    Response time: {d}ms\n", .{ms});
        if (doc_count) |dc| try app.print("    Documents in paperless: {s}\n", .{dc});
    } else {
        try app.print("\n  {s}✗ {s}{s}\n", .{ f.RED, message, f.RESET });
        if (url == null) try app.line("\n  Set env: export DV_PAPERLESS_URL=http://your-server:8000");
        if (token == null) if (app.config.zon_path == null)
            try app.line("  Set env: export DV_PAPERLESS_TOKEN=your-api-token")
        else if (app.config.get("paperless_keychain")) |service|
            try app.print("  Store it: security add-generic-password -a dv -s {s} -w\n", .{service})
        else
            try app.line("  Add .keychain = \"doddsville-paperless\" to .paperless in config.zon and store it:\n" ++
                "  security add-generic-password -a dv -s doddsville-paperless -w");
    }
}
