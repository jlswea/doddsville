//! Port of commands/config_cmd.py.

const std = @import("std");
const Io = std.Io;
const App = @import("../App.zig");
const f = @import("../format.zig");
const paperless = @import("../paperless.zig");

pub fn show(app: *App) !void {
    const c = app.config;
    try app.print("{s}Configuration:{s}\n", .{ f.BOLD, f.RESET });
    try app.print("  Config file: {s}{s}\n", .{ c.path orelse "(HOME not set)", if (c.found) "" else " (not found, using defaults)" });
    try app.print("  db: {s}\n", .{c.db});
    try app.print("  paperless.url: {s}\n", .{c.paperless.url orelse "(not set)"});
    try app.print("  paperless.keychain: {s}\n", .{c.paperless.keychain orelse "(not set)"});
}

pub fn check(app: *App) !void {
    try app.print("{s}Checking paperless-ngx connection...{s}\n\n", .{ f.BOLD, f.RESET });
    const url = app.config.paperless.url;
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
    try app.print("  {s} paperless.url: {s}\n", .{ if (url != null) ok_mark else bad_mark, url orelse "(not set)" });
    try app.print("  {s} token: {s}\n", .{ if (token != null) ok_mark else bad_mark, if (token != null) "(configured)" else "(not set)" });

    var message: []const u8 = undefined;
    var success = false;
    var response_ms: ?i64 = null;
    var doc_count: ?[]const u8 = null;

    if (url == null) {
        message = ".paperless.url not set";
    } else if (keychain_failed) {
        message = paperless.initMessage(error.Keychain);
    } else if (token == null) {
        message = ".paperless.keychain not set";
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
        if (url == null) try app.line("\n  Add .paperless.url to config.zon, e.g. .url = \"http://your-server:8000\"");
        if (token == null) if (app.config.paperless.keychain) |service|
            try app.print("  Store it: security add-generic-password -a dv -s {s} -w\n", .{service})
        else
            try app.line("  Add .keychain = \"doddsville-paperless\" to .paperless in config.zon and store it:\n" ++
                "  security add-generic-password -a dv -s doddsville-paperless -w");
    }
}
