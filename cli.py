"""Security data sensors: fill the securities table (ISIN, name, type).

Everything else lives in the Zig dv; the schema is its job too, so run dv
once on a new database before the sensors.
"""

import argparse
import sqlite3

from commands import handle_sensor
from config import DEFAULT_DB


def main() -> None:
    parser = argparse.ArgumentParser(description="dv sensors: fill the securities table")
    parser.add_argument(
        "--db", type=str, default=DEFAULT_DB, help=f"SQLite database file (default: {DEFAULT_DB})"
    )
    main_commands = parser.add_subparsers(dest="command", required=True, help="Available commands")

    parser_sensor = main_commands.add_parser("sensor", help="Manage security data sensors.")
    sensor_subcommands = parser_sensor.add_subparsers(
        dest="sensor_action", required=True, help="Sensor commands"
    )
    sensor_subcommands.add_parser("list", help="List available sensors")
    parser_sensor_run = sensor_subcommands.add_parser("run", help="Run sensor(s) to fetch security data")
    parser_sensor_run.add_argument(
        "sensor_name", nargs="?", default=None, help="Sensor name (omit to run all enabled)"
    )
    parser_sensor_run.add_argument(
        "--dry-run", action="store_true", help="Scrape and preview without writing to database"
    )

    args = parser.parse_args()
    conn = sqlite3.connect(args.db)
    handle_sensor(args, conn, conn.cursor())
    conn.close()


if __name__ == "__main__":
    main()
