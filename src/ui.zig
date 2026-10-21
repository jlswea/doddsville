//! Port of the interactive editors in ui.py used by `edit` and `doc edit`.

const std = @import("std");
const App = @import("App.zig");
const f = @import("format.zig");
const paperless = @import("paperless.zig");

pub const EditTxn = struct {
    type: []const u8,
    date: []const u8,
    security: []const u8,
    quantity: i64,
    unit_price_cents: i64,
    cost_cents: i64,
    confidence: []const u8 = "high",
    currency: []const u8,
    exchange_rate: f64,
};

const valid_types = [_][]const u8{ "buy", "sell", "dividend", "interest", "deposit", "withdrawal" };
const confidences = [_][]const u8{ "high", "medium", "low" };

fn preview(app: *App, t: EditTxn) !void {
    const a = app.a;
    const total_orig: i64 = if (t.unit_price_cents != 0 and t.quantity != 0) t.unit_price_cents * t.quantity else 0;
    const total_eur: i64 = @intFromFloat(@trunc(@as(f64, @floatFromInt(total_orig)) * t.exchange_rate));
    const net_eur = total_eur - t.cost_cents;

    try app.print("\n{s}Editing transaction #0:{s}\n", .{ f.BOLD, f.RESET });
    try app.print("  1. Type:         {s}\n", .{t.type});
    try app.print("  2. Date:         {s}\n", .{t.date});
    try app.print("  3. Security:     {s}\n", .{t.security});
    try app.print("  4. Quantity:     {d}\n", .{t.quantity});
    try app.print("  5. Unit price:   {s}\n", .{if (t.unit_price_cents != 0) try f.centsIn(a, t.unit_price_cents, t.currency) else "-"});
    try app.print("  6. Fees (EUR):   {s}\n", .{if (t.cost_cents != 0) try f.cents(a, t.cost_cents) else "-"});
    try app.print("  7. Confidence:   {s}\n", .{t.confidence});
    try app.print("  8. Currency:     {s}\n", .{t.currency});
    if (t.exchange_rate != 1.0)
        try app.print("  9. Exchange rate: {d:.6}\n", .{t.exchange_rate})
    else
        try app.line("  9. Exchange rate: 1.0 (no conversion)");
    try app.line("  ---");
    try app.print("  {s}Computed:{s}  Total: {s}  EUR: {s}  Net: {s}\n", .{
        f.BOLD,                                   f.RESET,
        try f.centsIn(a, total_orig, t.currency), try f.cents(a, total_eur),
        try f.cents(a, net_eur),
    });
    try app.print(" 10. {s}Delete this transaction{s}\n", .{ f.RED, f.RESET });
}

/// _input_cents: "12", "12.3", "12,34" all accepted; empty keeps current.
fn inputCents(app: *App, label: []const u8, current: i64, currency: []const u8) !i64 {
    const shown = if (current != 0) try f.centsIn(app.a, current, currency) else "-";
    var value = f.strip(try app.input(try app.fmt("{s} [{s}]: ", .{ label, shown })));
    if (value.len == 0) return current;
    if (std.mem.indexOfScalar(u8, value, '.') == null) value = try app.fmt("{s}.00", .{value});
    const norm = try std.mem.replaceOwned(u8, app.a, value, ",", ".");
    var parts = std.mem.splitScalar(u8, norm, '.');
    const euros_s = parts.next().?;
    const cents_s = parts.next() orelse "";
    const euros = std.fmt.parseInt(i64, euros_s, 10) catch return invalidAmount(app, current);
    var cbuf = [_]u8{ '0', '0' };
    const take = @min(cents_s.len, 2);
    @memcpy(cbuf[0..take], cents_s[0..take]);
    const cents = std.fmt.parseInt(i64, &cbuf, 10) catch return invalidAmount(app, current);
    const scaled = std.math.mul(i64, euros, 100) catch return invalidAmount(app, current);
    return std.math.add(i64, scaled, cents) catch invalidAmount(app, current);
}

fn invalidAmount(app: *App, current: i64) !i64 {
    try app.print("  {s}Invalid amount{s}\n", .{ f.RED, f.RESET });
    return current;
}

/// Returns null when the user chose to delete the transaction.
pub fn editTransaction(app: *App, txn: EditTxn) !?EditTxn {
    var t = txn;
    while (true) {
        try preview(app, t);
        const choice = f.strip(try app.input("\nEnter number to edit (or Enter to finish): "));
        if (choice.len == 0) return t;
        const field_num = std.fmt.parseInt(i64, choice, 10) catch {
            try app.print("{s}Please enter a number{s}\n", .{ f.RED, f.RESET });
            continue;
        };
        const before = t;
        switch (field_num) {
            1 => {
                try app.line("\nSelect type:");
                for (valid_types, 1..) |vt, i| try app.print("  {s}{d}{s}. {s}\n", .{ f.BLUE, i, f.RESET, vt });
                const s = f.strip(try app.input(try app.fmt("Type [current: {s}]: ", .{t.type})));
                if (s.len > 0) {
                    if (std.fmt.parseInt(i64, s, 10)) |idx| {
                        if (idx >= 1 and idx <= valid_types.len) t.type = valid_types[@intCast(idx - 1)];
                    } else |_| try app.print("  {s}Invalid choice{s}\n", .{ f.RED, f.RESET });
                }
            },
            2 => {
                const s = f.strip(try app.input(try app.fmt("Date (YYYY-MM-DD) [{s}]: ", .{t.date})));
                if (s.len > 0) t.date = s;
            },
            3 => {
                const s = f.strip(try app.input(try app.fmt("Security [{s}]: ", .{t.security})));
                if (s.len > 0) t.security = s;
            },
            4 => {
                const s = f.strip(try app.input(try app.fmt("Quantity [{d}]: ", .{t.quantity})));
                if (s.len > 0) {
                    if (std.fmt.parseInt(i64, s, 10)) |q| t.quantity = q else |_| try app.print("  {s}Invalid quantity{s}\n", .{ f.RED, f.RESET });
                }
            },
            5 => t.unit_price_cents = try inputCents(app, "Unit price", t.unit_price_cents, t.currency),
            6 => t.cost_cents = try inputCents(app, "Fees", t.cost_cents, "EUR"),
            7 => {
                try app.line("\nSelect confidence:");
                for (confidences, 1..) |cf, i| try app.print("  {s}{d}{s}. {s}\n", .{ f.BLUE, i, f.RESET, cf });
                const s = f.strip(try app.input(try app.fmt("Confidence [current: {s}]: ", .{t.confidence})));
                if (s.len > 0) {
                    if (std.fmt.parseInt(i64, s, 10)) |idx| {
                        if (idx >= 1 and idx <= 3) t.confidence = confidences[@intCast(idx - 1)];
                    } else |_| try app.print("  {s}Invalid choice{s}\n", .{ f.RED, f.RESET });
                }
            },
            8 => {
                try app.line("\nCommon currencies: EUR, USD, GBP, CHF");
                const s = f.strip(try app.input(try app.fmt("Currency [{s}]: ", .{t.currency})));
                if (s.len > 0) t.currency = try std.ascii.allocUpperString(app.a, s);
            },
            9 => {
                const s = f.strip(try app.input(try app.fmt("Exchange rate (to EUR) [{s}]: ", .{try f.pyFloat(app.a, t.exchange_rate)})));
                if (s.len > 0) {
                    const norm = try std.mem.replaceOwned(u8, app.a, s, ",", ".");
                    if (std.fmt.parseFloat(f64, norm)) |rate| {
                        if (rate > 0) t.exchange_rate = rate else try app.print("  {s}Rate must be positive{s}\n", .{ f.RED, f.RESET });
                    } else |_| try app.print("  {s}Invalid rate{s}\n", .{ f.RED, f.RESET });
                }
            },
            10 => {
                const s = f.strip(try app.input(try app.fmt("{s}Delete this transaction? (y/N): {s}", .{ f.RED, f.RESET })));
                if (std.ascii.eqlIgnoreCase(s, "y")) return null;
            },
            else => try app.print("{s}Invalid choice. Enter 1-10{s}\n", .{ f.RED, f.RESET }),
        }
        if (!totalFits(t)) {
            try app.print("  {s}Amount is too large; change discarded.{s}\n", .{ f.RED, f.RESET });
            t = before;
        }
    }
}

// Keeps the totals computed in `preview` and by the caller within i64.
fn totalFits(t: EditTxn) bool {
    const total = std.math.mul(i64, t.unit_price_cents, t.quantity) catch return false;
    const eur = @as(f64, @floatFromInt(total)) * t.exchange_rate;
    return @abs(eur) < 9.0e18;
}

// --------------------------------------------------------- document metadata

/// _get_name_by_id
fn nameByIdOwned(app: *App, items: []const paperless.Named, id: ?i64) ![]const u8 {
    const want = id orelse return "(none)";
    for (items) |it| if (it.id == want) return it.name;
    return app.fmt("(unknown: {d})", .{want});
}

fn tagNames(app: *App, tags: []const paperless.Named, ids: []const i64) ![]const u8 {
    if (ids.len == 0) return "(none)";
    var out: std.ArrayList(u8) = .empty;
    for (ids) |tid| for (tags) |t| if (t.id == tid) {
        if (out.items.len > 0) try out.appendSlice(app.a, ", ");
        try out.appendSlice(app.a, t.name);
        break;
    };
    return if (out.items.len > 0) out.items else "(none)";
}

fn orEmpty(s: []const u8) []const u8 {
    return if (s.len > 0) s else "(empty)";
}

pub const Lists = struct {
    correspondents: []const paperless.Named,
    doc_types: []const paperless.Named,
    storage_paths: []const paperless.Named,
    tags: []const paperless.Named,
};

fn previewMetadata(app: *App, m: paperless.DocumentMetadata, l: Lists) !void {
    try app.print("\n{s}Document Metadata Preview:{s}\n\n", .{ f.BOLD, f.RESET });
    try app.print("  1. Title:         {s}\n", .{orEmpty(m.title)});
    try app.print("  2. Date:          {s}\n", .{orEmpty(m.created)});
    try app.print("  3. Correspondent: {s}\n", .{try nameByIdOwned(app, l.correspondents, m.correspondent_id)});
    try app.print("  4. Type:          {s}\n", .{try nameByIdOwned(app, l.doc_types, m.document_type_id)});
    try app.print("  5. Storage Path:  {s}\n", .{try nameByIdOwned(app, l.storage_paths, m.storage_path_id)});
    try app.print("  6. Tags:          {s}\n", .{try tagNames(app, l.tags, m.tag_ids)});
    try app.print("  7. ASN:           {s}\n", .{orEmpty(m.archive_serial_number)});
}

fn selectFromList(app: *App, items: []const paperless.Named, prompt: []const u8) !?i64 {
    try app.print("\n{s}\n", .{prompt});
    try app.print("  {s}0{s}. (none)\n", .{ f.BLUE, f.RESET });
    for (items, 1..) |it, i| try app.print("  {s}{d}{s}. {s}\n", .{ f.BLUE, i, f.RESET, it.name });
    while (true) {
        const s = f.strip(try app.input("Choice [0]: "));
        if (s.len == 0) return null;
        const idx = std.fmt.parseInt(i64, s, 10) catch {
            try app.print("  {s}Please enter a number{s}\n", .{ f.RED, f.RESET });
            continue;
        };
        if (idx == 0) return null;
        if (idx >= 1 and idx <= items.len) return items[@intCast(idx - 1)].id;
        try app.print("  {s}Invalid choice. Enter 0-{d}{s}\n", .{ f.RED, items.len, f.RESET });
    }
}

fn selectTags(app: *App, tags: []const paperless.Named, current: []const i64) ![]const i64 {
    try app.line("\nSelect tags (enter numbers separated by comma, or empty for none):");
    for (tags, 1..) |t, i| {
        const marker: []const u8 = if (std.mem.indexOfScalar(i64, current, t.id) != null) "*" else " ";
        try app.print("  {s}{d}{s}. [{s}] {s}\n", .{ f.BLUE, i, f.RESET, marker, t.name });
    }
    while (true) {
        var shown: std.ArrayList(u8) = .empty;
        for (tags, 1..) |t, i| if (std.mem.indexOfScalar(i64, current, t.id) != null) {
            if (shown.items.len > 0) try shown.appendSlice(app.a, ", ");
            try shown.print(app.a, "{d}", .{i});
        };
        const s = f.strip(try app.input(try app.fmt("Tags [{s}]: ", .{if (shown.items.len > 0) shown.items else "none"})));
        if (s.len == 0) return current;
        if (std.ascii.eqlIgnoreCase(s, "none") or std.mem.eql(u8, s, "0")) return &.{};

        var selected: std.ArrayList(i64) = .empty;
        var bad = false;
        var it = std.mem.splitScalar(u8, s, ',');
        while (it.next()) |part| {
            const idx = std.fmt.parseInt(i64, f.strip(part), 10) catch {
                bad = true;
                break;
            };
            if (idx >= 1 and idx <= tags.len) {
                try selected.append(app.a, tags[@intCast(idx - 1)].id);
            } else try app.print("  {s}Invalid index: {d}{s}\n", .{ f.RED, idx, f.RESET });
        }
        if (bad) {
            try app.print("  {s}Please enter numbers separated by comma{s}\n", .{ f.RED, f.RESET });
            continue;
        }
        return selected.items;
    }
}

pub fn editDocumentMetadata(app: *App, metadata: paperless.DocumentMetadata, l: Lists) !paperless.DocumentMetadata {
    var m = metadata;
    while (true) {
        try previewMetadata(app, m, l);
        try app.line("");
        const choice = f.strip(try app.input("Enter number to edit (or Enter to confirm): "));
        if (choice.len == 0) return m;
        const n = std.fmt.parseInt(i64, choice, 10) catch {
            try app.print("{s}Please enter a number{s}\n", .{ f.RED, f.RESET });
            continue;
        };
        switch (n) {
            1 => {
                const s = f.strip(try app.input(try app.fmt("Title [{s}]: ", .{m.title})));
                if (s.len > 0) m.title = s;
            },
            2 => {
                const s = f.strip(try app.input(try app.fmt("Date (YYYY-MM-DD) [{s}]: ", .{m.created})));
                if (s.len > 0) m.created = s;
            },
            3 => m.correspondent_id = try selectFromList(app, l.correspondents, "Select correspondent:"),
            4 => m.document_type_id = try selectFromList(app, l.doc_types, "Select document type:"),
            5 => m.storage_path_id = try selectFromList(app, l.storage_paths, "Select storage path:"),
            6 => m.tag_ids = try selectTags(app, l.tags, m.tag_ids),
            7 => {
                const s = f.strip(try app.input(try app.fmt("ASN [{s}]: ", .{m.archive_serial_number})));
                if (s.len > 0) m.archive_serial_number = s;
            },
            else => try app.print("{s}Invalid choice. Enter 1-7{s}\n", .{ f.RED, f.RESET }),
        }
    }
}
