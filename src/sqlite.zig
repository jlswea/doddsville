//! Minimal SQLite binding. `@cImport` is gone in Zig 0.17, so instead of
//! pulling in translate-c we declare the handful of C functions we use.

const std = @import("std");

const Handle = opaque {};
const StmtHandle = opaque {};

extern fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*Handle, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern fn sqlite3_close_v2(db: *Handle) c_int;
extern fn sqlite3_errmsg(db: *Handle) [*:0]const u8;
extern fn sqlite3_exec(db: *Handle, sql: [*:0]const u8, cb: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
extern fn sqlite3_prepare_v2(db: *Handle, sql: [*]const u8, n: c_int, stmt: *?*StmtHandle, tail: ?*?[*]const u8) c_int;
extern fn sqlite3_step(stmt: *StmtHandle) c_int;
extern fn sqlite3_finalize(stmt: *StmtHandle) c_int;
extern fn sqlite3_bind_int64(stmt: *StmtHandle, idx: c_int, v: i64) c_int;
extern fn sqlite3_bind_double(stmt: *StmtHandle, idx: c_int, v: f64) c_int;
extern fn sqlite3_bind_text(stmt: *StmtHandle, idx: c_int, v: [*]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
extern fn sqlite3_bind_null(stmt: *StmtHandle, idx: c_int) c_int;
extern fn sqlite3_column_type(stmt: *StmtHandle, col: c_int) c_int;
extern fn sqlite3_column_int64(stmt: *StmtHandle, col: c_int) i64;
extern fn sqlite3_column_double(stmt: *StmtHandle, col: c_int) f64;
extern fn sqlite3_column_text(stmt: *StmtHandle, col: c_int) ?[*]const u8;
extern fn sqlite3_column_bytes(stmt: *StmtHandle, col: c_int) c_int;
extern fn sqlite3_last_insert_rowid(db: *Handle) i64;

const SQLITE_OK = 0;
const SQLITE_CONSTRAINT = 19;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const SQLITE_NULL = 5;
const SQLITE_OPEN_READWRITE = 0x02;
const SQLITE_OPEN_CREATE = 0x04;
const SQLITE_OPEN_FULLMUTEX = 0x10000;

/// SQLITE_TRANSIENT: SQLite copies bound text immediately.
const transient: ?*const anyopaque = @ptrFromInt(std.math.maxInt(usize));

pub const Error = error{ Sqlite, Constraint, OutOfMemory };

pub const Db = struct {
    handle: *Handle,

    pub fn open(path: [:0]const u8) Error!Db {
        var h: ?*Handle = null;
        const rc = sqlite3_open_v2(path.ptr, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, null);
        if (rc != SQLITE_OK) {
            if (h) |hh| {
                std.log.err("cannot open database '{s}': {s}", .{ path, std.mem.span(sqlite3_errmsg(hh)) });
                _ = sqlite3_close_v2(hh);
            }
            return error.Sqlite;
        }
        return .{ .handle = h.? };
    }

    pub fn close(db: Db) void {
        _ = sqlite3_close_v2(db.handle);
    }

    pub fn errmsg(db: Db) []const u8 {
        return std.mem.span(sqlite3_errmsg(db.handle));
    }

    /// Run one or more statements without parameters.
    pub fn exec(db: Db, sql: [:0]const u8) Error!void {
        const rc = sqlite3_exec(db.handle, sql.ptr, null, null, null);
        if (rc != SQLITE_OK) return db.fail(rc);
    }

    pub fn prepare(db: Db, sql: []const u8) Error!Stmt {
        var s: ?*StmtHandle = null;
        const rc = sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &s, null);
        if (rc != SQLITE_OK) return db.fail(rc);
        return .{ .handle = s.?, .db = db };
    }

    /// Prepare, bind `args`, step once and finalize. For INSERT/UPDATE/DELETE.
    pub fn run(db: Db, sql: []const u8, args: anytype) Error!void {
        var st = try db.prepare(sql);
        defer st.finalize();
        try st.bindAll(args);
        _ = try st.step();
    }

    pub fn lastInsertRowId(db: Db) i64 {
        return sqlite3_last_insert_rowid(db.handle);
    }

    fn fail(db: Db, rc: c_int) Error {
        if (rc & 0xff == SQLITE_CONSTRAINT) return error.Constraint;
        std.log.err("sqlite: {s}", .{db.errmsg()});
        return error.Sqlite;
    }
};

pub const Stmt = struct {
    handle: *StmtHandle,
    db: Db,

    pub fn finalize(st: *Stmt) void {
        _ = sqlite3_finalize(st.handle);
    }

    /// Bind a tuple of values to `?` parameters, in order. Supported element
    /// types: integers, floats, `[]const u8`-like strings, optionals of those
    /// (null binds SQL NULL) and `null`.
    pub fn bindAll(st: *Stmt, args: anytype) Error!void {
        inline for (args, 1..) |arg, i| try st.bindOne(@intCast(i), arg);
    }

    pub fn bindOne(st: *Stmt, idx: c_int, arg: anytype) Error!void {
        const T = @TypeOf(arg);
        const rc: c_int = switch (@typeInfo(T)) {
            .null => sqlite3_bind_null(st.handle, idx),
            .optional => if (arg) |v| return st.bindOne(idx, v) else sqlite3_bind_null(st.handle, idx),
            .int, .comptime_int => sqlite3_bind_int64(st.handle, idx, @intCast(arg)),
            .float, .comptime_float => sqlite3_bind_double(st.handle, idx, @floatCast(arg)),
            .pointer => blk: {
                const s: []const u8 = arg;
                break :blk sqlite3_bind_text(st.handle, idx, s.ptr, @intCast(s.len), transient);
            },
            else => @compileError("cannot bind type " ++ @typeName(T)),
        };
        if (rc != SQLITE_OK) return st.db.fail(rc);
    }

    /// Returns true when a row is available, false when done.
    pub fn step(st: *Stmt) Error!bool {
        const rc = sqlite3_step(st.handle);
        return switch (rc) {
            SQLITE_ROW => true,
            SQLITE_DONE => false,
            else => st.db.fail(rc),
        };
    }

    pub fn isNull(st: *Stmt, col: c_int) bool {
        return sqlite3_column_type(st.handle, col) == SQLITE_NULL;
    }

    pub fn int(st: *Stmt, col: c_int) i64 {
        return sqlite3_column_int64(st.handle, col);
    }

    pub fn optInt(st: *Stmt, col: c_int) ?i64 {
        return if (st.isNull(col)) null else st.int(col);
    }

    pub fn float(st: *Stmt, col: c_int) f64 {
        return sqlite3_column_double(st.handle, col);
    }

    pub fn optFloat(st: *Stmt, col: c_int) ?f64 {
        return if (st.isNull(col)) null else st.float(col);
    }

    /// Valid only until the next `step`/`finalize`; use `text` to keep it.
    pub fn textRef(st: *Stmt, col: c_int) ?[]const u8 {
        if (st.isNull(col)) return null;
        const p = sqlite3_column_text(st.handle, col) orelse return null;
        const n: usize = @intCast(sqlite3_column_bytes(st.handle, col));
        return p[0..n];
    }

    /// Text is copied into `a` because SQLite's buffer dies on the next step.
    pub fn text(st: *Stmt, a: std.mem.Allocator, col: c_int) Error!?[]const u8 {
        if (st.isNull(col)) return null;
        const p = sqlite3_column_text(st.handle, col) orelse return null;
        const n: usize = @intCast(sqlite3_column_bytes(st.handle, col));
        return try a.dupe(u8, p[0..n]);
    }
};

test "open, insert, query" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.exec("create table t (id integer primary key, name text, v real);");
    try db.run("insert into t (name, v) values (?, ?)", .{ "a€", 1.5 });
    try db.run("insert into t (name, v) values (?, ?)", .{ @as(?[]const u8, null), null });
    try std.testing.expectEqual(@as(i64, 2), db.lastInsertRowId());
    var st = try db.prepare("select name, v from t order by id");
    defer st.finalize();
    try std.testing.expect(try st.step());
    const name = (try st.text(std.testing.allocator, 0)).?;
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("a€", name);
    try std.testing.expectEqual(@as(f64, 1.5), st.float(1));
    try std.testing.expect(try st.step());
    try std.testing.expect(st.isNull(0));
    try std.testing.expect(!try st.step());
}
