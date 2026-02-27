import argparse
import sqlite3
from datetime import datetime

from commands import (
    handle_account,
    handle_add,
    handle_config,
    handle_doc,
    handle_edit,
    handle_import,
    handle_list,
    handle_report,
    handle_sensor,
)
from config import DEFAULT_DB, load_config
from migrations import run_migrations
from formatting import (
    BOLD,
    GREEN,
    RED,
    RESET,
    YELLOW,
    cents_from_decimal_string,
    format_cents,
    format_cents_colored,
    validate_date_format,
)

# Re-exports so test_cli.py (import cli; cli.X) keeps working
from db import get_or_prompt_account, get_or_prompt_security
from paperless import insert_transaction_documents


def main() -> None:
    parser = argparse.ArgumentParser(
        description="dv: Managing common stocks transactions"
    )

    main_commands = parser.add_subparsers(
        dest="command", required=True, help="Available commands"
    )

    # --------------------------------------------------------------------------
    #                           COMMAND: "account"
    # --------------------------------------------------------------------------

    parser_account = main_commands.add_parser("account", help="Manage accounts")
    account_subcommands = parser_account.add_subparsers(
        dest="account_action", required=True, help="Account commands"
    )

    # --- "account add" sub-command ---
    parser_account_add = account_subcommands.add_parser("add", help="Add a new account")
    parser_account_add.add_argument("name", type=str, help="Account name")

    # --- "account list" sub-command ---
    account_subcommands.add_parser("list", help="List all accounts")

    # --------------------------------------------------------------------------
    #                           COMMAND: "list"
    # --------------------------------------------------------------------------

    parser_list = main_commands.add_parser(
        "list", help="List all recorded transactions."
    )
    parser_list.add_argument("--account", "-a", type=str, help="Filter by account name")
    parser_list.add_argument(
        "--type", "-t", type=str, help="Filter by transaction type"
    )

    # --------------------------------------------------------------------------
    #                           COMMAND: "add"
    # --------------------------------------------------------------------------

    parser_add = main_commands.add_parser("add", help="Add a new transaction.")

    add_transaction_types = parser_add.add_subparsers(
        dest="transaction_type", required=True, help="Type of transaction to add"
    )

    # Common arguments for transactions that need an account
    def add_common_args(p, needs_company=False):
        p.add_argument("--account", "-a", type=str, help="Account name")
        p.add_argument(
            "--date",
            type=validate_date_format,
            default=datetime.now().strftime("%d.%m.%Y"),
            help="Transaction date (DD.MM.YYYY)",
        )
        p.add_argument(
            "--cost",
            "-c",
            type=cents_from_decimal_string,
            default=0,
            help="Fees/costs in euros (e.g., 1.50)",
        )
        p.add_argument(
            "--doc",
            "-d",
            nargs="+",
            help="Paperless document ID(s) or file path(s) to upload",
        )

    # --- "add buy" sub-command ---
    parser_buy = add_transaction_types.add_parser(
        "buy", help="Record a stock purchase."
    )
    parser_buy.add_argument("identifier", type=str, help="Security name or ISIN")
    parser_buy.add_argument("quantity", type=int, help="Number of shares bought")
    parser_buy.add_argument(
        "price", type=cents_from_decimal_string, help="Price per share (e.g., 123.45)"
    )
    add_common_args(parser_buy, needs_company=True)

    # --- "add sell" sub-command ---
    parser_sell = add_transaction_types.add_parser("sell", help="Record a stock sale.")
    parser_sell.add_argument("name", type=str, help="Company name")
    parser_sell.add_argument("quantity", type=int, help="Number of shares sold")
    parser_sell.add_argument(
        "price", type=cents_from_decimal_string, help="Price per share (e.g., 123.45)"
    )
    add_common_args(parser_sell, needs_company=True)

    # --- "add dividend" sub-command ---
    parser_div = add_transaction_types.add_parser(
        "dividend", help="Record a dividend payment."
    )
    parser_div.add_argument("name", type=str, help="Company name")
    parser_div.add_argument(
        "amount",
        type=cents_from_decimal_string,
        help="Total dividend amount (e.g., 50.00)",
    )
    add_common_args(parser_div, needs_company=True)

    # --- "add interest" sub-command ---
    parser_interest = add_transaction_types.add_parser(
        "interest", help="Record interest on cash balance."
    )
    parser_interest.add_argument(
        "amount", type=cents_from_decimal_string, help="Interest amount (e.g., 10.00)"
    )
    add_common_args(parser_interest)

    # --- "add deposit" sub-command ---
    parser_deposit = add_transaction_types.add_parser(
        "deposit", help="Record a deposit/contribution."
    )
    parser_deposit.add_argument(
        "amount", type=cents_from_decimal_string, help="Deposit amount (e.g., 1000.00)"
    )
    add_common_args(parser_deposit)

    # --- "add withdrawal" sub-command ---
    parser_withdrawal = add_transaction_types.add_parser(
        "withdrawal", help="Record a withdrawal."
    )
    parser_withdrawal.add_argument(
        "amount",
        type=cents_from_decimal_string,
        help="Withdrawal amount (e.g., 500.00)",
    )
    add_common_args(parser_withdrawal)

    # --- "add transfer" sub-command ---
    parser_transfer = add_transaction_types.add_parser(
        "transfer", help="Record a transfer between accounts."
    )
    parser_transfer.add_argument(
        "amount", type=cents_from_decimal_string, help="Transfer amount (e.g., 500.00)"
    )
    parser_transfer.add_argument(
        "--from", dest="from_account", type=str, required=True, help="Source account"
    )
    parser_transfer.add_argument(
        "--to", dest="to_account", type=str, required=True, help="Destination account"
    )
    parser_transfer.add_argument(
        "--date",
        "-d",
        type=validate_date_format,
        default=datetime.now().strftime("%d.%m.%Y"),
        help="Transaction date (DD.MM.YYYY)",
    )
    parser_transfer.add_argument(
        "--cost",
        "-c",
        type=cents_from_decimal_string,
        default=0,
        help="Transfer fees (e.g., 0.50)",
    )
    parser_transfer.add_argument(
        "--doc",
        nargs="+",
        help="Paperless document ID(s) or file path(s) to upload",
    )

    # --------------------------------------------------------------------------
    #                           COMMAND: "edit"
    # --------------------------------------------------------------------------

    parser_edit = main_commands.add_parser("edit", help="Edit an existing transaction.")
    parser_edit.add_argument("transaction_id", type=int, help="Transaction ID to edit")

    # --------------------------------------------------------------------------
    #                           COMMAND: "report"
    # --------------------------------------------------------------------------

    parser_report = main_commands.add_parser(
        "report", help="Generate reports on accounts and investments."
    )
    report_subcommands = parser_report.add_subparsers(
        dest="report_type", required=True, help="Type of report"
    )

    # Common report arguments
    def add_report_args(p):
        p.add_argument("--account", "-a", type=str, help="Filter by account name")
        p.add_argument(
            "--from",
            dest="from_date",
            type=validate_date_format,
            help="Start date (DD.MM.YYYY)",
        )
        p.add_argument(
            "--to",
            dest="to_date",
            type=validate_date_format,
            help="End date (DD.MM.YYYY)",
        )

    # --- "report summary" sub-command ---
    parser_summary = report_subcommands.add_parser(
        "summary", help="Compact overview of all metrics."
    )
    add_report_args(parser_summary)

    # --- "report balance" sub-command ---
    parser_balance = report_subcommands.add_parser(
        "balance", help="Show cash balance per account."
    )
    add_report_args(parser_balance)

    # --- "report cashflow" sub-command ---
    parser_cashflow = report_subcommands.add_parser(
        "cashflow", help="Show cash flow summary (deposits, withdrawals, net)."
    )
    add_report_args(parser_cashflow)

    # --- "report holdings" sub-command ---
    parser_holdings = report_subcommands.add_parser(
        "holdings", help="Show current stock holdings per account."
    )
    add_report_args(parser_holdings)

    # --- "report performance" sub-command ---
    parser_performance = report_subcommands.add_parser(
        "performance",
        help="Show investment performance (realized & unrealized gains/losses).",
    )
    add_report_args(parser_performance)

    # --------------------------------------------------------------------------
    #                           COMMAND: "doc"
    # --------------------------------------------------------------------------

    parser_doc = main_commands.add_parser(
        "doc", help="Manage documents linked to transactions."
    )
    doc_subcommands = parser_doc.add_subparsers(
        dest="doc_action", required=True, help="Document commands"
    )

    # --- "doc add" sub-command ---
    parser_doc_add = doc_subcommands.add_parser(
        "add", help="Link paperless document(s) to a transaction"
    )
    parser_doc_add.add_argument(
        "transaction_id", type=int, help="Transaction ID to link documents to"
    )
    parser_doc_add.add_argument(
        "docs",
        nargs="+",
        help="Paperless document ID(s) or file path(s) to upload",
    )

    # --- "doc edit" sub-command ---
    parser_doc_edit = doc_subcommands.add_parser(
        "edit", help="Edit metadata of a Paperless document"
    )
    parser_doc_edit.add_argument(
        "doc_id", type=int, help="Paperless document ID to edit"
    )

    # --------------------------------------------------------------------------
    #                           COMMAND: "config"
    # --------------------------------------------------------------------------

    parser_config = main_commands.add_parser("config", help="Manage CLI configuration.")
    config_subcommands = parser_config.add_subparsers(
        dest="config_action", required=True, help="Config commands"
    )

    # --- "config show" sub-command ---
    config_subcommands.add_parser("show", help="Show current configuration")

    # --- "config set" sub-command ---
    parser_config_set = config_subcommands.add_parser(
        "set", help="Set a configuration value"
    )
    parser_config_set.add_argument("key", type=str, help="Config key (e.g., db)")
    parser_config_set.add_argument("value", type=str, help="Config value")

    # --- "config check" sub-command ---
    config_subcommands.add_parser("check", help="Check paperless-ngx API connection")

    # --------------------------------------------------------------------------
    #                           COMMAND: "import"
    # --------------------------------------------------------------------------

    parser_import = main_commands.add_parser(
        "import", help="Import transactions from a PDF document using AI parsing."
    )
    parser_import.add_argument(
        "pdf_file", type=str, nargs="?", help="Path to the PDF file to import"
    )
    parser_import.add_argument(
        "--account",
        "-a",
        type=str,
        help="Target account name (will prompt if not specified)",
    )
    parser_import.add_argument(
        "--dry-run",
        action="store_true",
        help="Parse and preview only, don't insert transactions",
    )
    parser_import.add_argument(
        "--no-upload",
        action="store_true",
        help="Don't upload PDF to paperless after import",
    )
    parser_import.add_argument(
        "--model",
        type=str,
        help="Override Ollama model (default from config or mistral)",
    )
    parser_import.add_argument(
        "--raw", action="store_true", help="Show raw extracted text (for debugging)"
    )
    parser_import.add_argument(
        "--parser",
        "-p",
        type=str,
        help="Force a specific parser (e.g., 'scalable', 'llm')",
    )
    parser_import.add_argument(
        "--list-parsers", action="store_true", help="List available parsers and exit"
    )

    # --------------------------------------------------------------------------
    #                           COMMAND: "sensor"
    # --------------------------------------------------------------------------

    parser_sensor = main_commands.add_parser(
        "sensor", help="Manage security data sensors."
    )
    sensor_subcommands = parser_sensor.add_subparsers(
        dest="sensor_action", required=True, help="Sensor commands"
    )

    # --- "sensor list" sub-command ---
    sensor_subcommands.add_parser("list", help="List available sensors")

    # --- "sensor run" sub-command ---
    parser_sensor_run = sensor_subcommands.add_parser(
        "run", help="Run sensor(s) to fetch security data"
    )
    parser_sensor_run.add_argument(
        "sensor_name",
        nargs="?",
        default=None,
        help="Sensor name (omit to run all enabled)",
    )
    parser_sensor_run.add_argument(
        "--dry-run",
        action="store_true",
        help="Scrape and preview without writing to database",
    )

    # --- "--version, -v" ---
    parser.add_argument(
        "-v",
        "--version",
        action="version",
        version="doddsville@0.0.3",
        help="The installed version of the doddsville CLI",
    )

    # --- "--db" ---
    parser.add_argument(
        "--db",
        type=str,
        default=None,
        help="Path to SQLite database file (overrides config)",
    )

    # --------------------------------------------------------------------------
    #                           Parse args & dispatch
    # --------------------------------------------------------------------------
    args = parser.parse_args()

    # Load configuration
    config = load_config()

    # Handle config command (doesn't need database)
    if args.command == "config":
        handle_config(args, config)
        return

    # Determine database path (--db flag overrides config)
    db_path = args.db if args.db else config.get("db", DEFAULT_DB)

    conn = sqlite3.connect(db_path)
    run_migrations(conn)
    cur = conn.cursor()
    cur.execute("PRAGMA foreign_keys = ON;")

    if args.command == "account":
        handle_account(args, conn, cur)
    elif args.command == "doc":
        handle_doc(args, config, conn, cur)
    elif args.command == "edit":
        handle_edit(args, config, conn, cur)
    elif args.command == "import":
        handle_import(args, config, conn, cur)
    elif args.command == "list":
        handle_list(args, config, cur)
    elif args.command == "add":
        handle_add(args, config, conn, cur)
    elif args.command == "report":
        handle_report(args, cur)
    elif args.command == "sensor":
        handle_sensor(args, conn, cur)

    conn.close()


if __name__ == "__main__":
    main()
