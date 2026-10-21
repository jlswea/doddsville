//! Port of paperless.py: the paperless-ngx REST API over std.http.Client.

const std = @import("std");
const Io = std.Io;
const json = std.json;
const Allocator = std.mem.Allocator;

const App = @import("App.zig");
const f = @import("format.zig");

pub const Named = struct { id: i64, name: []const u8 };

pub const DocumentMetadata = struct {
    title: []const u8 = "",
    created: []const u8 = "", // YYYY-MM-DD
    correspondent_id: ?i64 = null,
    document_type_id: ?i64 = null,
    storage_path_id: ?i64 = null,
    tag_ids: []const i64 = &.{},
    archive_serial_number: []const u8 = "",
};

pub const Error = error{ NotConfigured, Http, Connection, UploadFailed, Timeout, BadResponse } ||
    Allocator.Error || Io.Cancelable;

pub const Response = struct { status: std.http.Status, body: []const u8 };

pub const max_response_size = 1024 * 1024;

// The document detail endpoint otherwise includes the full OCR text (`content`), which dv never uses.
pub const document_fields = "?fields=id,title,created,correspondent,document_type,storage_path,tags,archive_serial_number,custom_fields";

// Shared by all clients: each response body is only valid until the next request.
var response_buf: [max_response_size]u8 = undefined;
var redirect_buf: [8 * 1024]u8 = undefined;

pub const Client = struct {
    app: *App,
    base_url: []const u8,
    auth: []const u8,
    http: std.http.Client,
    /// Human-readable description of the last error (like str(exception) in Python).
    last_error: []const u8 = "",

    /// Equivalent of get_paperless_headers: fails when URL/token are missing.
    pub fn init(app: *App) Error!Client {
        const url = app.config.get("paperless_url") orelse "";
        const token = app.config.get("paperless_token") orelse "";
        if (url.len == 0 or token.len == 0) return error.NotConfigured;
        return .{
            .app = app,
            .base_url = std.mem.trimEnd(u8, url, "/"),
            .auth = try app.fmt("Token {s}", .{token}),
            .http = .{ .allocator = app.a, .io = app.io },
        };
    }

    pub fn deinit(c: *Client) void {
        c.http.deinit();
    }

    pub fn describe(c: *Client, err: anyerror) []const u8 {
        return switch (err) {
            error.NotConfigured => "paperless_url and paperless_token must be configured",
            else => if (c.last_error.len > 0) c.last_error else @errorName(err),
        };
    }

    pub fn request(c: *Client, method: std.http.Method, path: []const u8, payload: ?[]const u8, content_type: ?[]const u8) Error!Response {
        const url = try c.app.fmt("{s}{s}", .{ c.base_url, path });
        var body: Io.Writer = .fixed(&response_buf);
        const result = c.http.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .response_writer = &body,
            .redirect_buffer = &redirect_buf,
            .headers = .{
                .authorization = .{ .override = c.auth },
                .content_type = if (content_type) |ct| .{ .override = ct } else .default,
                // Compressed responses would need a decompression window allocated per request.
                .accept_encoding = .{ .override = "identity" },
            },
        }) catch |err| return c.transportError(err, url);
        return .{ .status = result.status, .body = body.buffered() };
    }

    fn transportError(c: *Client, err: anyerror, url: []const u8) Error {
        c.last_error = switch (err) {
            error.WriteFailed => try c.app.fmt("Response from {s} is larger than {d} KiB", .{ url, max_response_size / 1024 }),
            error.ConnectionRefused, error.NetworkUnreachable, error.HostUnreachable, error.ConnectionResetByPeer, error.UnknownHostName, error.NameServerFailure => try c.app.fmt("Cannot connect to {s}", .{c.base_url}),
            else => try c.app.fmt("Request error: {s} ({s})", .{ @errorName(err), url }),
        };
        return error.Connection;
    }

    /// request + raise_for_status
    pub fn ok(c: *Client, method: std.http.Method, path: []const u8, payload: ?[]const u8, content_type: ?[]const u8) Error!Response {
        return c.checkStatus(try c.request(method, path, payload, content_type), path);
    }

    fn checkStatus(c: *Client, r: Response, path: []const u8) Error!Response {
        const code = @intFromEnum(r.status);
        if (code >= 400) {
            c.last_error = try c.app.fmt("{d} {s} Error: {s} for url: {s}{s}", .{
                code,
                if (code < 500) "Client" else "Server",
                r.status.phrase() orelse "",
                c.base_url,
                path,
            });
            return error.Http;
        }
        return r;
    }

    pub fn getJson(c: *Client, path: []const u8) Error!json.Value {
        const r = try c.ok(.GET, path, null, null);
        return c.parse(r.body);
    }

    pub fn sendJson(c: *Client, method: std.http.Method, path: []const u8, body: []const u8) Error!json.Value {
        const r = try c.ok(method, path, body, "application/json");
        return c.parse(r.body);
    }

    fn parse(c: *Client, body: []const u8) Error!json.Value {
        // alloc_always: the parsed value must not point into the reused response buffer.
        return json.parseFromSliceLeaky(json.Value, c.app.a, body, .{ .allocate = .alloc_always }) catch {
            c.last_error = "invalid JSON from paperless";
            return error.BadResponse;
        };
    }

    pub fn documentExists(c: *Client, doc_id: i64) Error!bool {
        const r = try c.request(.GET, try c.app.fmt("/api/documents/{d}/?fields=id", .{doc_id}), null, null);
        return r.status == .ok;
    }

    /// fetch_paperless_{correspondents,document_types,storage_paths,tags}
    pub fn fetchNamed(c: *Client, endpoint: []const u8) Error![]const Named {
        const r = try c.ok(.GET, try c.app.fmt("/api/{s}/?page_size=1000", .{endpoint}), null, null);
        // Parsing into the two fields we use is far smaller than a generic json.Value tree.
        const Page = struct { results: []const Named = &.{} };
        const page = json.parseFromSliceLeaky(Page, c.app.a, r.body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch {
            c.last_error = "invalid JSON from paperless";
            return error.BadResponse;
        };
        return page.results;
    }

    pub fn getOrCreateCustomField(c: *Client) Error!i64 {
        const v = try c.getJson("/api/custom_fields/?page_size=1000");
        if (field(v, "results")) |res| if (res == .array) for (res.array.items) |cf| {
            const name = asStr(field(cf, "name")) orelse continue;
            if (std.mem.eql(u8, name, "dv_transaction_id")) return asInt(field(cf, "id")) orelse return error.BadResponse;
        };
        const created = try c.sendJson(.POST, "/api/custom_fields/", "{\"name\":\"dv_transaction_id\",\"data_type\":\"string\"}");
        return asInt(field(created, "id")) orelse error.BadResponse;
    }

    /// Set or merge the dv_transaction_id custom field on a document.
    pub fn setDocumentTransactionIds(c: *Client, doc_id: i64, field_id: i64, txn_ids: []const i64) Error!void {
        const a = c.app.a;
        const path = try c.app.fmt("/api/documents/{d}/", .{doc_id});
        const doc = try c.getJson(try c.app.fmt("{s}{s}", .{ path, document_fields }));
        const cfs: []const json.Value = if (field(doc, "custom_fields")) |v| (if (v == .array) v.array.items else &.{}) else &.{};

        var ids: std.ArrayList(i64) = .empty;
        for (cfs) |cf| {
            if (asInt(field(cf, "field")) != field_id) continue;
            const val = field(cf, "value") orelse continue;
            const s = switch (val) {
                .string => |s| s,
                .integer => |n| try c.app.fmt("{d}", .{n}),
                else => continue,
            };
            var parts = std.mem.splitScalar(u8, s, ',');
            while (parts.next()) |p| {
                const t = f.strip(p);
                if (t.len > 0 and allDigits(t)) try addUnique(a, &ids, std.fmt.parseInt(i64, t, 10) catch continue);
            }
        }
        for (txn_ids) |id| try addUnique(a, &ids, id);
        std.mem.sort(i64, ids.items, {}, std.sort.asc(i64));

        var merged: std.ArrayList(u8) = .empty;
        for (ids.items, 0..) |id, i| {
            if (i > 0) try merged.append(a, ',');
            try merged.print(a, "{d}", .{id});
        }

        // Keep the document's other custom fields untouched.
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, "{\"custom_fields\":[");
        var first = true;
        for (cfs) |cf| {
            if (asInt(field(cf, "field")) == field_id) continue;
            if (!first) try out.append(a, ',');
            first = false;
            try out.appendSlice(a, try json.Stringify.valueAlloc(a, cf, .{}));
        }
        if (!first) try out.append(a, ',');
        try out.appendSlice(a, try json.Stringify.valueAlloc(a, .{ .field = field_id, .value = merged.items }, .{}));
        try out.appendSlice(a, "]}");
        _ = try c.sendJson(.PATCH, path, out.items);
    }

    /// POST `head ++ <file contents> ++ tail`, streaming the file from disk.
    fn postFile(c: *Client, url: []const u8, content_type: []const u8, head: []const u8, file: Io.File, size: u64, tail: []const u8) !Response {
        var req = try c.http.request(.POST, try std.Uri.parse(url), .{
            .redirect_behavior = .unhandled,
            .headers = .{
                .authorization = .{ .override = c.auth },
                .content_type = .{ .override = content_type },
                .accept_encoding = .{ .override = "identity" },
            },
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = head.len + size + tail.len };

        var send_buf: [16 * 1024]u8 = undefined;
        var body = try req.sendBodyUnflushed(&send_buf);
        try body.writer.writeAll(head);
        var read_buf: [16 * 1024]u8 = undefined;
        var file_reader = file.reader(c.app.io, &read_buf);
        if (try file_reader.interface.streamRemaining(&body.writer) != size) return error.FileChangedDuringUpload;
        try body.writer.writeAll(tail);
        try body.end();
        try req.connection.?.flush();

        var response = try req.receiveHead(&.{});
        var out: Io.Writer = .fixed(&response_buf);
        var transfer_buf: [64]u8 = undefined;
        _ = response.reader(&transfer_buf).streamRemaining(&out) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
            else => |e| return e,
        };
        return .{ .status = response.head.status, .body = out.buffered() };
    }

    /// POST /api/documents/post_document/ and wait for the consumer task.
    pub fn upload(c: *Client, file_path: []const u8, dv_tag_id: i64, metadata: ?DocumentMetadata, remove_tag_ids: []const i64) (Error || error{ReadFailed})!i64 {
        const a = c.app.a;
        const io = c.app.io;
        const file = Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
            c.last_error = try c.app.fmt("cannot read {s}: {s}", .{ file_path, @errorName(err) });
            return error.ReadFailed;
        };
        defer file.close(io);
        const size = (file.stat(io) catch |err| {
            c.last_error = try c.app.fmt("cannot read {s}: {s}", .{ file_path, @errorName(err) });
            return error.ReadFailed;
        }).size;

        const boundary = "----dvFormBoundary7MA4YWxkTrZu0gW";
        const head = try c.app.fmt("--{s}\r\nContent-Disposition: form-data; name=\"document\"; filename=\"{s}\"\r\nContent-Type: application/octet-stream\r\n\r\n", .{ boundary, std.fs.path.basename(file_path) });
        var tail: std.ArrayList(u8) = .empty;
        try tail.appendSlice(a, "\r\n");

        const Field = struct { []const u8, []const u8 };
        var fields: std.ArrayList(Field) = .empty;
        if (metadata) |m| {
            if (m.title.len > 0) try fields.append(a, .{ "title", m.title });
            if (m.created.len > 0) try fields.append(a, .{ "created", m.created });
            if (m.correspondent_id) |id| if (id != 0) try fields.append(a, .{ "correspondent", try c.app.fmt("{d}", .{id}) });
            if (m.document_type_id) |id| if (id != 0) try fields.append(a, .{ "document_type", try c.app.fmt("{d}", .{id}) });
            if (m.storage_path_id) |id| if (id != 0) try fields.append(a, .{ "storage_path", try c.app.fmt("{d}", .{id}) });
            for (m.tag_ids) |tid| if (tid != dv_tag_id) try fields.append(a, .{ "tags", try c.app.fmt("{d}", .{tid}) });
            if (m.archive_serial_number.len > 0) try fields.append(a, .{ "archive_serial_number", m.archive_serial_number });
        }
        try fields.append(a, .{ "tags", try c.app.fmt("{d}", .{dv_tag_id}) });
        for (fields.items) |fl|
            try tail.print(a, "--{s}\r\nContent-Disposition: form-data; name=\"{s}\"\r\n\r\n{s}\r\n", .{ boundary, fl[0], fl[1] });
        try tail.print(a, "--{s}--\r\n", .{boundary});

        const post_path = "/api/documents/post_document/";
        const url = try c.app.fmt("{s}{s}", .{ c.base_url, post_path });
        const sent = c.postFile(url, "multipart/form-data; boundary=" ++ boundary, head, file, size, tail.items) catch |err|
            return c.transportError(err, url);
        const r = try c.checkStatus(sent, post_path);
        const task_id = try a.dupe(u8, std.mem.trim(u8, f.strip(r.body), "\""));

        var doc_id: ?i64 = null;
        var tries: usize = 0;
        while (tries < 120) : (tries += 1) { // max 2 minutes for OCR
            try c.app.io.sleep(.fromSeconds(1), .awake);
            const tasks = try c.getJson(try c.app.fmt("/api/tasks/?task_id={s}", .{task_id}));
            if (tasks != .array or tasks.array.items.len == 0) continue;
            const t = tasks.array.items[0];
            const status = asStr(field(t, "status")) orelse "";
            if (std.mem.eql(u8, status, "SUCCESS")) {
                doc_id = asInt(field(t, "related_document")) orelse return error.BadResponse;
                break;
            } else if (std.mem.eql(u8, status, "FAILURE")) {
                const res = field(t, "result");
                c.last_error = try c.app.fmt("Document upload failed: {s}", .{if (res) |v| (asStr(v) orelse "?") else "None"});
                return error.UploadFailed;
            }
        }
        const id = doc_id orelse {
            c.last_error = "Document was uploaded but timed out waiting for paperless to finish processing. Check paperless inbox for the document.";
            return error.Timeout;
        };

        // Paperless workflows may add inbox/todo tags; strip them again.
        if (remove_tag_ids.len > 0) {
            const path = try c.app.fmt("/api/documents/{d}/", .{id});
            const doc = try c.getJson(try c.app.fmt("{s}{s}", .{ path, document_fields }));
            var current: std.ArrayList(i64) = .empty;
            var removed = false;
            if (field(doc, "tags")) |tv| if (tv == .array) for (tv.array.items) |tag| {
                const tid = asInt(tag) orelse continue;
                if (std.mem.indexOfScalar(i64, remove_tag_ids, tid) != null) {
                    removed = true;
                } else try current.append(a, tid);
            };
            if (removed) _ = c.request(.PATCH, path, try json.Stringify.valueAlloc(a, .{ .tags = current.items }, .{}), "application/json") catch {};
        }
        return id;
    }
};

// ---------------------------------------------------------------- JSON helpers

pub fn field(v: json.Value, key: []const u8) ?json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

pub fn asInt(v: ?json.Value) ?i64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| n,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

pub fn asStr(v: ?json.Value) ?[]const u8 {
    const x = v orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

pub fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

fn addUnique(a: Allocator, list: *std.ArrayList(i64), v: i64) !void {
    if (std.mem.indexOfScalar(i64, list.items, v) == null) try list.append(a, v);
}

// ------------------------------------------------------- dv-side helpers

pub const Resolved = struct { ids: []const i64, failed: []const []const u8 };

fn pathExists(app: *App, p: []const u8) bool {
    Io.Dir.cwd().access(app.io, p, .{}) catch return false;
    return true;
}

/// Port of resolve_doc_args: numeric args are verified, existing files are
/// uploaded; failures are collected and reported, never fatal.
pub fn resolveDocArgs(app: *App, doc_args: []const []const u8) !Resolved {
    var ids: std.ArrayList(i64) = .empty;
    var failed: std.ArrayList([]const u8) = .empty;

    var needs_upload = false;
    for (doc_args) |arg| if (!allDigits(arg) and pathExists(app, arg)) {
        needs_upload = true;
    };

    var client_opt: ?Client = Client.init(app) catch null;
    defer if (client_opt) |*cl| cl.deinit();

    var dv_tag_id: ?i64 = null;
    var remove_tag_ids: std.ArrayList(i64) = .empty;
    var abrechnung_id: ?i64 = null;
    if (needs_upload) {
        const cl = if (client_opt) |*cl| cl else {
            try app.print("  {s}✗{s} Failed: paperless_url and paperless_token must be configured\n", .{ f.RED, f.RESET });
            return .{ .ids = &.{}, .failed = doc_args };
        };
        const tags = cl.fetchNamed("tags") catch |err| return failAll(app, cl, err, doc_args);
        for (tags) |t| {
            if (std.mem.eql(u8, t.name, "dv")) {
                dv_tag_id = t.id;
            } else if (std.mem.eql(u8, t.name, "todo") or std.mem.eql(u8, t.name, "inbox")) {
                try remove_tag_ids.append(app.a, t.id);
            }
        }
        const types = cl.fetchNamed("document_types") catch |err| return failAll(app, cl, err, doc_args);
        for (types) |t| if (std.mem.eql(u8, t.name, "Abrechnung")) {
            abrechnung_id = t.id;
            break;
        };
        var missing: std.ArrayList(u8) = .empty;
        if (dv_tag_id == null) try missing.appendSlice(app.a, "tag 'dv'");
        if (abrechnung_id == null) {
            if (missing.items.len > 0) try missing.appendSlice(app.a, ", ");
            try missing.appendSlice(app.a, "document type 'Abrechnung'");
        }
        if (missing.items.len > 0) {
            try app.print("{s}✗ Cannot upload: {s} not found in paperless-ngx.{s}\n", .{ f.RED, missing.items, f.RESET });
            try app.line("  Please create the missing item(s) in paperless before uploading documents.");
            return .{ .ids = &.{}, .failed = doc_args };
        }
    }

    for (doc_args) |arg| {
        if (allDigits(arg)) {
            const doc_id = std.fmt.parseInt(i64, arg, 10) catch {
                try failed.append(app.a, arg);
                continue;
            };
            try app.print("Verifying document {d}...\n", .{doc_id});
            const cl = if (client_opt) |*cl| cl else {
                try app.print("  {s}✗{s} Failed: paperless_url and paperless_token must be configured\n", .{ f.RED, f.RESET });
                try failed.append(app.a, arg);
                continue;
            };
            const exists = cl.documentExists(doc_id) catch |err| {
                try app.print("  {s}✗{s} Failed: {s}\n", .{ f.RED, f.RESET, cl.describe(err) });
                try failed.append(app.a, arg);
                continue;
            };
            if (exists) {
                try ids.append(app.a, doc_id);
                try app.print("  {s}✓{s} Document {d} exists\n", .{ f.GREEN, f.RESET, doc_id });
            } else {
                try app.print("  {s}✗{s} Document {d} not found in paperless\n", .{ f.RED, f.RESET, doc_id });
                try failed.append(app.a, arg);
            }
        } else if (pathExists(app, arg)) {
            const cl = &client_opt.?; // checked above
            try app.print("Uploading {s} to paperless-ngx...\n", .{arg});
            const tag_ids = try app.a.dupe(i64, &.{dv_tag_id.?});
            const doc_id = cl.upload(arg, dv_tag_id.?, .{ .tag_ids = tag_ids, .document_type_id = abrechnung_id }, remove_tag_ids.items) catch |err| {
                try app.print("  {s}✗{s} Failed: {s}\n", .{ f.RED, f.RESET, cl.describe(err) });
                try failed.append(app.a, arg);
                continue;
            };
            try app.print("  {s}✓{s} Uploaded as document {d}\n", .{ f.GREEN, f.RESET, doc_id });
            try ids.append(app.a, doc_id);
        } else {
            try app.print("  {s}✗{s} {s} is not a valid ID or file path\n", .{ f.RED, f.RESET, arg });
            try failed.append(app.a, arg);
        }
    }
    return .{ .ids = ids.items, .failed = failed.items };
}

fn failAll(app: *App, cl: *Client, err: anyerror, doc_args: []const []const u8) !Resolved {
    try app.print("  {s}✗{s} Failed: {s}\n", .{ f.RED, f.RESET, cl.describe(err) });
    return .{ .ids = &.{}, .failed = doc_args };
}

pub fn insertTransactionDocuments(app: *App, txn_id: i64, doc_ids: []const i64) !void {
    for (doc_ids) |d|
        try app.db.run("INSERT INTO transaction_document (transaction_id, paperless_id) VALUES (?, ?)", .{ txn_id, d });
}

/// Link documents on both sides: rows in transaction_document plus the
/// dv_transaction_id custom field in paperless. Shared by `add` and `doc add`.
pub fn backlink(app: *App, doc_ids: []const i64, txn_ids: []const i64) !void {
    var cl = Client.init(app) catch |err| {
        try app.print("  {s}Warning: Could not set transaction ID custom field: {s}{s}\n", .{ f.YELLOW, switch (err) {
            error.NotConfigured => "paperless_url and paperless_token must be configured",
            else => @errorName(err),
        }, f.RESET });
        return;
    };
    defer cl.deinit();
    const cf_id = cl.getOrCreateCustomField() catch |err| {
        try app.print("  {s}Warning: Could not set transaction ID custom field: {s}{s}\n", .{ f.YELLOW, cl.describe(err), f.RESET });
        return;
    };
    for (doc_ids) |did| cl.setDocumentTransactionIds(did, cf_id, txn_ids) catch |err| {
        try app.print("  {s}Warning: Could not set transaction ID custom field: {s}{s}\n", .{ f.YELLOW, cl.describe(err), f.RESET });
        return;
    };
}
