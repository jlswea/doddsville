#!/usr/bin/env python3
"""
Migration script to update database schema from old to new format.

Changes:
- Renames idx -> index, com -> company, raw -> raw_html
- Drops old trans table (no real data per user)
- Creates account table
- Creates new transaction table with expanded types
"""
import sqlite3
import shutil
from datetime import datetime


def migrate(db_path: str = "data.db"):
    # Create backup
    backup_path = f"data.db.backup.{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    shutil.copy(db_path, backup_path)
    print(f"Created backup: {backup_path}")

    conn = sqlite3.connect(db_path)
    cur = conn.cursor()

    # Check current schema
    cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
    existing_tables = {row[0] for row in cur.fetchall()}
    print(f"Existing tables: {existing_tables}")

    # Rename idx -> "index" (quoted because it's a reserved keyword)
    if "idx" in existing_tables and "index" not in existing_tables:
        cur.execute('ALTER TABLE idx RENAME TO "index"')
        print("Renamed idx -> index")

    # Rename com -> company
    if "com" in existing_tables and "company" not in existing_tables:
        cur.execute("ALTER TABLE com RENAME TO company")
        print("Renamed com -> company")

    # Rename raw -> raw_html
    if "raw" in existing_tables and "raw_html" not in existing_tables:
        cur.execute("ALTER TABLE raw RENAME TO raw_html")
        print("Renamed raw -> raw_html")

    # Drop old trans table
    if "trans" in existing_tables:
        cur.execute("DROP TABLE trans")
        print("Dropped old trans table")

    # Create account table
    if "account" not in existing_tables:
        cur.execute("""
            CREATE TABLE account (
                id INTEGER PRIMARY KEY ASC,
                name TEXT NOT NULL UNIQUE
            )
        """)
        print("Created account table")

    # Create new transaction table
    cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='transaction'")
    if not cur.fetchone():
        cur.execute("""
            CREATE TABLE "transaction" (
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
            )
        """)
        print("Created transaction table")

    conn.commit()
    conn.close()
    print("Migration complete!")


if __name__ == "__main__":
    migrate()
