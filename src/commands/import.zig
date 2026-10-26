//! Port of commands/import_cmd.py: broker PDFs into transactions.

const std = @import("std");
const App = @import("../App.zig");
const f = @import("../format.zig");
const pdf = @import("../pdf/pdf.zig");

pub const max_pdf_size = 1024 * 1024;
/// Caps each decoded PDF stream; page contents of the supported statements are under 100 KiB.
const decode_limit = 512 * 1024;

/// Reports problems itself and returns null.
pub fn extract(app: *App, path: []const u8) !?[]const pdf.Page {
    const src = std.Io.Dir.cwd().readFileAlloc(app.io, path, app.a, .limited(max_pdf_size)) catch |err| switch (err) {
        error.FileNotFound => {
            try app.print("{s}PDF file not found: {s}{s}\n", .{ f.RED, path, f.RESET });
            return null;
        },
        error.StreamTooLong => {
            try app.print("{s}PDF is larger than {d} KiB: {s}{s}\n", .{ f.RED, max_pdf_size / 1024, path, f.RESET });
            return null;
        },
        else => return err,
    };
    return pdf.extract(app.a, src, decode_limit) catch |err| switch (err) {
        error.OutOfMemory => err,
        else => {
            try app.print("{s}Could not read {s}: {s}{s}\n", .{ f.RED, path, @errorName(err), f.RESET });
            return null;
        },
    };
}

pub fn raw(app: *App, path: []const u8) !void {
    const pages = (try extract(app, path)) orelse return error.Reported;
    for (pages, 1..) |page, i| {
        try app.print("--- Page {d} ---\n", .{i});
        for (page.lines) |l| try app.line(l.text);
    }
}
