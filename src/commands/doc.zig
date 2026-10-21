//! Port of commands/doc_cmd.py.

const std = @import("std");
const json = std.json;
const App = @import("../App.zig");
const f = @import("../format.zig");
const paperless = @import("../paperless.zig");
const ui = @import("../ui.zig");

pub fn add(app: *App, txn_id: i64, docs: []const []const u8) !void {
    {
        var st = try app.db.prepare("SELECT id FROM \"transaction\" WHERE id = ?");
        defer st.finalize();
        try st.bindAll(.{txn_id});
        if (!try st.step()) {
            try app.print("{s}Transaction {d} not found.{s}\n", .{ f.RED, txn_id, f.RESET });
            return;
        }
    }

    const resolved = try paperless.resolveDocArgs(app, docs);
    if (resolved.ids.len > 0) {
        var existing: std.ArrayList(i64) = .empty;
        {
            var st = try app.db.prepare("SELECT paperless_id FROM transaction_document WHERE transaction_id = ?");
            defer st.finalize();
            try st.bindAll(.{txn_id});
            while (try st.step()) try existing.append(app.a, st.int(0));
        }
        var new_docs: std.ArrayList(i64) = .empty;
        var dups: std.ArrayList(i64) = .empty;
        for (resolved.ids) |d| {
            if (std.mem.indexOfScalar(i64, existing.items, d) != null) try dups.append(app.a, d) else try new_docs.append(app.a, d);
        }
        if (dups.items.len > 0) {
            try app.print("{s}Skipping already linked documents: ", .{f.YELLOW});
            for (dups.items, 0..) |d, i| try app.print("{s}{d}", .{ if (i > 0) ", " else "", d });
            try app.print("{s}\n", .{f.RESET});
        }
        if (new_docs.items.len > 0) {
            try paperless.insertTransactionDocuments(app, txn_id, new_docs.items);
            try app.print("{s}Linked {d} document(s) to transaction {d}.{s}\n", .{ f.GREEN, new_docs.items.len, txn_id, f.RESET });
            try paperless.backlink(app, new_docs.items, &.{txn_id});
        } else if (dups.items.len == 0) {
            try app.line("No documents were linked.");
        }
    } else {
        try app.print("{s}No valid documents to link.{s}\n", .{ f.RED, f.RESET });
    }

    if (resolved.failed.len > 0) {
        try app.print("\n{s}Failed to process:{s}\n", .{ f.YELLOW, f.RESET });
        for (resolved.failed) |x| try app.print("  - {s}\n", .{x});
    }
}

pub fn edit(app: *App, doc_id: i64) !void {
    var cl = paperless.Client.init(app) catch |err| {
        try app.print("{s}{s}{s}\n", .{ f.RED, switch (err) {
            error.NotConfigured => "paperless_url and paperless_token must be configured",
            else => @errorName(err),
        }, f.RESET });
        return;
    };
    defer cl.deinit();
    editInner(app, &cl, doc_id) catch |err| switch (err) {
        error.Http, error.Connection, error.BadResponse => {
            try app.print("{s}{s}{s}\n", .{ f.RED, cl.describe(err), f.RESET });
            return error.Reported;
        },
        else => return err,
    };
}

fn editInner(app: *App, cl: *paperless.Client, doc_id: i64) !void {
    const a = app.a;
    const path = try app.fmt("/api/documents/{d}/", .{doc_id});
    const get_path = try app.fmt("{s}{s}", .{ path, paperless.document_fields });
    const r = try cl.request(.GET, get_path, null, null);
    if (r.status == .not_found) {
        try app.print("{s}Document {d} not found in Paperless.{s}\n", .{ f.RED, doc_id, f.RESET });
        return;
    }
    const doc = try cl.getJson(get_path);

    const lists: ui.Lists = .{
        .correspondents = try cl.fetchNamed("correspondents"),
        .doc_types = try cl.fetchNamed("document_types"),
        .storage_paths = try cl.fetchNamed("storage_paths"),
        .tags = try cl.fetchNamed("tags"),
    };

    var tag_ids: std.ArrayList(i64) = .empty;
    if (paperless.field(doc, "tags")) |tv| if (tv == .array) for (tv.array.items) |t| {
        if (paperless.asInt(t)) |id| try tag_ids.append(a, id);
    };
    const asn: []const u8 = if (paperless.field(doc, "archive_serial_number")) |v| switch (v) {
        .integer => |n| try app.fmt("{d}", .{n}),
        .string => |s| s,
        else => "",
    } else "";

    const meta = try ui.editDocumentMetadata(app, .{
        .title = paperless.asStr(paperless.field(doc, "title")) orelse "",
        .created = paperless.asStr(paperless.field(doc, "created")) orelse "",
        .correspondent_id = paperless.asInt(paperless.field(doc, "correspondent")),
        .document_type_id = paperless.asInt(paperless.field(doc, "document_type")),
        .storage_path_id = paperless.asInt(paperless.field(doc, "storage_path")),
        .tag_ids = tag_ids.items,
        .archive_serial_number = asn,
    }, lists);

    const Patch = struct {
        title: []const u8,
        created: ?[]const u8,
        correspondent: ?i64,
        document_type: ?i64,
        storage_path: ?i64,
        tags: []const i64,
    };
    const patch: Patch = .{
        .title = meta.title,
        .created = if (meta.created.len > 0) meta.created else null,
        .correspondent = meta.correspondent_id,
        .document_type = meta.document_type_id,
        .storage_path = meta.storage_path_id,
        .tags = meta.tag_ids,
    };
    const body = if (meta.archive_serial_number.len > 0)
        try json.Stringify.valueAlloc(a, .{
            .title = patch.title,
            .created = patch.created,
            .correspondent = patch.correspondent,
            .document_type = patch.document_type,
            .storage_path = patch.storage_path,
            .tags = patch.tags,
            .archive_serial_number = meta.archive_serial_number,
        }, .{})
    else
        try json.Stringify.valueAlloc(a, patch, .{});
    _ = try cl.ok(.PATCH, path, body, "application/json");
    try app.print("{s}Document {d} updated.{s}\n", .{ f.GREEN, doc_id, f.RESET });

    // Make sure the backlink (dv_transaction_id) exists on the document.
    var linked: std.ArrayList(i64) = .empty;
    {
        var st = try app.db.prepare("SELECT transaction_id FROM transaction_document WHERE paperless_id = ?");
        defer st.finalize();
        try st.bindAll(.{doc_id});
        while (try st.step()) try linked.append(a, st.int(0));
    }
    if (linked.items.len == 0) return;

    const cf_id = cl.getOrCreateCustomField() catch |err| {
        try app.print("  {s}Warning: Could not set transaction ID custom field: {s}{s}\n", .{ f.YELLOW, cl.describe(err), f.RESET });
        return;
    };
    var has_field = false;
    if (paperless.field(doc, "custom_fields")) |cfs| if (cfs == .array) for (cfs.array.items) |cf| {
        if (paperless.asInt(paperless.field(cf, "field")) != cf_id) continue;
        const v = paperless.field(cf, "value") orelse continue;
        const truthy = switch (v) {
            .null => false,
            .string => |s| s.len > 0,
            .integer => |n| n != 0,
            else => true,
        };
        if (truthy) has_field = true;
    };
    if (has_field) return;
    cl.setDocumentTransactionIds(doc_id, cf_id, linked.items) catch |err| {
        try app.print("  {s}Warning: Could not set transaction ID custom field: {s}{s}\n", .{ f.YELLOW, cl.describe(err), f.RESET });
        return;
    };
    try app.out.writeAll("  Set dv_transaction_id: ");
    for (linked.items, 0..) |id, i| try app.print("{s}{d}", .{ if (i > 0) "," else "", id });
    try app.out.writeAll("\n");
}
