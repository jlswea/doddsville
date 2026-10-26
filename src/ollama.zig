//! Local Ollama API (/api/generate), used only as the import fallback.

const std = @import("std");
const App = @import("App.zig");

pub const max_response_size = 256 * 1024;
var response_buf: [max_response_size]u8 = undefined;

pub const Error = error{ Connection, ModelNotFound, Http, BadResponse } || std.mem.Allocator.Error;

pub const Client = struct {
    app: *App,
    url: []const u8,
    model: []const u8,
    /// Human-readable description of the last error.
    last_error: []const u8 = "",

    pub fn init(app: *App, model_override: ?[]const u8) Client {
        return .{
            .app = app,
            .url = std.mem.trimEnd(u8, app.config.ollama.url, "/"),
            .model = model_override orelse app.config.ollama.model,
        };
    }

    /// The model's complete answer, valid until the next call.
    pub fn generate(c: *Client, prompt: []const u8) Error![]const u8 {
        const a = c.app.a;
        var http: std.http.Client = .{ .allocator = a, .io = c.app.io };
        defer http.deinit();
        const body = try std.json.Stringify.valueAlloc(a, .{ .model = c.model, .prompt = prompt, .stream = false, .format = "json" }, .{});
        var out: std.Io.Writer = .fixed(&response_buf);
        const result = http.fetch(.{
            .location = .{ .url = try c.app.fmt("{s}/api/generate", .{c.url}) },
            .method = .POST,
            .payload = body,
            .response_writer = &out,
            .headers = .{ .content_type = .{ .override = "application/json" }, .accept_encoding = .{ .override = "identity" } },
        }) catch |err| {
            c.last_error = switch (err) {
                error.WriteFailed => try c.app.fmt("Ollama's answer is larger than {d} KiB", .{max_response_size / 1024}),
                else => try c.app.fmt("Cannot connect to Ollama at {s}. Start with: ollama serve", .{c.url}),
            };
            return error.Connection;
        };
        if (result.status == .not_found) {
            c.last_error = try c.app.fmt("Model '{s}' not found. Pull with: ollama pull {s}", .{ c.model, c.model });
            return error.ModelNotFound;
        }
        if (@backingInt(result.status) >= 400) {
            c.last_error = try c.app.fmt("Ollama API error: {d}", .{@backingInt(result.status)});
            return error.Http;
        }
        const Reply = struct { response: []const u8 = "" };
        const reply = std.json.parseFromSliceLeaky(Reply, a, out.buffered(), .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            c.last_error = "invalid JSON from Ollama";
            return error.BadResponse;
        };
        return reply.response;
    }
};
