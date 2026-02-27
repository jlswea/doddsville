"""
Lightweight schema migrations using SQLite PRAGMA user_version.

Each migration function brings the DB from version N-1 to N.
All statements use IF NOT EXISTS / column-existence checks so they
are safe to run on both fresh and already-migrated databases.
"""

import sqlite3


def _get_version(conn: sqlite3.Connection) -> int:
    return conn.execute("PRAGMA user_version").fetchone()[0]


def _set_version(conn: sqlite3.Connection, version: int) -> None:
    conn.execute(f"PRAGMA user_version = {version}")


def _migration_001(conn: sqlite3.Connection) -> None:
    """Initial schema: index, company, raw_html, account, transaction."""
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS "index" (
            id INTEGER PRIMARY KEY ASC,
            name TEXT,
            url TEXT
        );

        CREATE TABLE IF NOT EXISTS company (
            id INTEGER PRIMARY KEY ASC,
            isin TEXT,
            name TEXT,
            url TEXT
        );

        CREATE TABLE IF NOT EXISTS raw_html (
            id INTEGER PRIMARY KEY ASC,
            com INTEGER,
            html TEXT,
            timestamp TEXT,
            FOREIGN KEY (com) REFERENCES company (id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS account (
            id INTEGER PRIMARY KEY ASC,
            name TEXT NOT NULL UNIQUE
        );

        CREATE TABLE IF NOT EXISTS "transaction" (
            id INTEGER PRIMARY KEY ASC,
            account INTEGER NOT NULL REFERENCES account (id),
            company INTEGER REFERENCES company (id),
            type TEXT CHECK (type IN (
                'buy',
                'sell',
                'dividend',
                'interest',
                'deposit',
                'withdrawal',
                'transfer'
            )),
            total_value INTEGER,
            unit_value INTEGER,
            quantity INTEGER,
            cost INTEGER,
            date DATE NOT NULL,
            linked_transaction INTEGER REFERENCES "transaction" (id),
            FOREIGN KEY (company) REFERENCES company (id) ON DELETE CASCADE
        );
    """)


def _migration_002(conn: sqlite3.Connection) -> None:
    """Add transaction_document table for paperless-ngx integration."""
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS transaction_document (
            id INTEGER PRIMARY KEY ASC,
            transaction_id INTEGER NOT NULL REFERENCES "transaction" (id) ON DELETE CASCADE,
            paperless_id INTEGER NOT NULL,
            UNIQUE(transaction_id, paperless_id)
        );
    """)


def _migration_003(conn: sqlite3.Connection) -> None:
    """Add currency and exchange_rate columns to transaction table."""
    cur = conn.execute('PRAGMA table_info("transaction")')
    columns = {row[1] for row in cur.fetchall()}

    if "currency" not in columns:
        conn.execute(
            "ALTER TABLE \"transaction\" ADD COLUMN currency TEXT DEFAULT 'EUR'"
        )
    if "exchange_rate" not in columns:
        conn.execute(
            'ALTER TABLE "transaction" ADD COLUMN exchange_rate REAL DEFAULT 1.0'
        )


def _migration_004(conn: sqlite3.Connection) -> None:
    """Rename company table to security, add type column, rename company column in transaction, drop legacy tables."""
    # Rename company table to security
    conn.execute("ALTER TABLE company RENAME TO security")

    # Add type column to security table
    cur = conn.execute("PRAGMA table_info(security)")
    columns = {row[1] for row in cur.fetchall()}
    if "type" not in columns:
        conn.execute("ALTER TABLE security ADD COLUMN type TEXT DEFAULT 'stock'")

    # Rename company column to security in transaction table
    conn.execute('ALTER TABLE "transaction" RENAME COLUMN company TO security')

    # Drop legacy tables
    conn.execute('DROP TABLE IF EXISTS raw_html')
    conn.execute('DROP TABLE IF EXISTS "index"')


_MIGRATIONS = [_migration_001, _migration_002, _migration_003, _migration_004]


def run_migrations(conn: sqlite3.Connection) -> None:
    """Run any pending migrations and bump user_version after each."""
    current = _get_version(conn)
    for i, migrate in enumerate(_MIGRATIONS[current:], start=current + 1):
        migrate(conn)
        _set_version(conn, i)
        conn.commit()
