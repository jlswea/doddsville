#!/usr/bin/env python3
"""Demo script to showcase CLI functionality with sample data."""
import os
import sqlite3
import subprocess
import tempfile


def run(db_path, args, confirm=True):
    """Run dv CLI command and print output."""
    cmd = ["pixi", "run", "dv", "--db", db_path] + args
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        input="y\n" if confirm else None,
    )
    print(result.stdout)
    if result.stderr:
        print(result.stderr)


def main():
    # Create temporary database from schema
    fd, db_path = tempfile.mkstemp(suffix=".db")
    os.close(fd)

    conn = sqlite3.connect(db_path)
    with open("schema.sql") as f:
        conn.executescript(f.read())

    # Add sample companies
    conn.execute("INSERT INTO company (isin, name) VALUES ('US0378331005', 'Apple Inc.')")
    conn.execute("INSERT INTO company (isin, name) VALUES ('US5949181045', 'Microsoft Corp.')")
    conn.commit()
    conn.close()

    print(f"Demo database: {db_path}")
    print("=" * 70)
    print("SETTING UP SAMPLE DATA")
    print("=" * 70)

    # Create accounts
    run(db_path, ["account", "add", "Scalable Broker"], confirm=False)
    run(db_path, ["account", "add", "Trade Republic"], confirm=False)

    # Deposits
    run(db_path, ["add", "deposit", "5000.00", "-a", "Scalable", "-d", "01.01.2024"])
    run(db_path, ["add", "deposit", "3000.00", "-a", "Trade", "-d", "01.01.2024"])

    # Buy stocks
    run(db_path, ["add", "buy", "Apple", "20", "185.50", "-a", "Scalable", "-d", "15.01.2024", "-c", "1.00"])
    run(db_path, ["add", "buy", "Microsoft", "10", "380.00", "-a", "Trade", "-d", "20.01.2024", "-c", "1.00"])

    # Transfer between accounts
    run(db_path, ["add", "transfer", "500.00", "--from", "Scalable", "--to", "Trade", "-d", "01.03.2024"])

    # Dividend
    run(db_path, ["add", "dividend", "Apple", "48.00", "-a", "Scalable", "-d", "15.03.2024"])

    # Sell some shares (with profit)
    run(db_path, ["add", "sell", "Apple", "10", "195.00", "-a", "Scalable", "-d", "15.06.2024", "-c", "1.00"])

    # Interest
    run(db_path, ["add", "interest", "25.00", "-a", "Scalable", "-d", "30.06.2024"])

    print("=" * 70)
    print("TRANSACTION LIST")
    print("=" * 70)
    run(db_path, ["list"], confirm=False)

    print("=" * 70)
    print("REPORTS")
    print("=" * 70)

    print("\n--- Summary Report ---")
    run(db_path, ["report", "summary"], confirm=False)

    print("\n--- Balance Report ---")
    run(db_path, ["report", "balance"], confirm=False)

    print("\n--- Cash Flow Report ---")
    run(db_path, ["report", "cashflow"], confirm=False)

    print("\n--- Holdings Report ---")
    run(db_path, ["report", "holdings"], confirm=False)

    print("\n--- Performance Report ---")
    run(db_path, ["report", "performance"], confirm=False)

    # Cleanup
    os.unlink(db_path)
    print("=" * 70)
    print("Demo complete. Temporary database deleted.")


if __name__ == "__main__":
    main()
