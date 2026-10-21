//! Invariants of the stored ledger, checked before a write is committed.

const std = @import("std");
const assert = std.debug.assert;
const sqlite = @import("sqlite.zig");

/// The two legs of a transfer reference each other and cancel out.
pub fn assertTransferPair(db: sqlite.Db, a: i64, b: i64) !void {
    assert(a != b);
    var st = try db.prepare(
        \\SELECT COUNT(*),
        \\       COALESCE(SUM(total_value), 0),
        \\       SUM((id = ?1 AND linked_transaction = ?2) OR (id = ?2 AND linked_transaction = ?1))
        \\FROM "transaction" WHERE id IN (?1, ?2) AND type = 'transfer'
    );
    defer st.finalize();
    try st.bindAll(.{ a, b });
    assert(try st.step());
    assert(st.int(0) == 2);
    assert(st.int(1) == 0);
    assert(st.int(2) == 2);
}

test "transfer pair" {
    const db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.exec(
        \\CREATE TABLE "transaction" (id INTEGER PRIMARY KEY, type TEXT, total_value INTEGER, linked_transaction INTEGER);
        \\INSERT INTO "transaction" VALUES (1, 'transfer', -500, 2), (2, 'transfer', 500, 1);
    );
    try assertTransferPair(db, 1, 2);
    try assertTransferPair(db, 2, 1);
}
