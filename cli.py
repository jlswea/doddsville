import argparse
import sqlite3
import time
from datetime import datetime
from pathlib import Path

import requests


# ANSI escape codes
RESET = "\033[0m"
BOLD = "\033[1m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
BLUE = "\033[34m"

# Configuration
CONFIG_DIR = Path.home() / ".doddsville"
CONFIG_FILE = CONFIG_DIR / "config"
DEFAULT_DB = "data.db"


def load_config():
    """Load configuration from ~/.doddsville/config file."""
    config = {"db": DEFAULT_DB}

    if CONFIG_FILE.exists():
        with open(CONFIG_FILE) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    config[key.strip()] = value.strip()

    return config


def save_config(config):
    """Save configuration to ~/.doddsville/config file."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        for key, value in config.items():
            f.write(f"{key}={value}\n")


def cents_from_decimal_string(value):
    """
    Custom type for argparse that converts a string with exactly two decimal
    places (e.g., '12.34') into an integer representing cents (1234).
    It bypasses float conversion to avoid precision issues.
    """
    if not isinstance(value, str):
        raise argparse.ArgumentTypeError(f"'{value}' is not a string.")

    if "." not in value:
        raise argparse.ArgumentTypeError(
            f"'{value}' must have exactly two decimal places (e.g., '12.34')."
        )

    integer_part, decimal_part = value.split(".")

    if len(decimal_part) != 2:
        raise argparse.ArgumentTypeError(
            f"'{value}' must have exactly two decimal places."
        )

    cents_string = integer_part + decimal_part

    try:
        return int(cents_string)
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"'{value}' contains non-numeric characters that prevent conversion to cents."
        )


def validate_date_format(date_string):
    """
    Custom type function for argparse to validate and parse date strings.
    Raises ValueError if the format doesn't match DD.MM.YYYY.
    """
    try:
        date_object = datetime.strptime(date_string, "%d.%m.%Y")
        return date_object
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"Invalid date format: '{date_string}'. Expected DD.MM.YYYY."
        )


def format_cents(cents):
    """Format cents as euros with 2 decimal places."""
    return f"€{(cents / 100):.2f}"


def format_cents_colored(cents):
    """Format cents with color (green positive, red negative)."""
    formatted = format_cents(abs(cents))
    if cents > 0:
        return f"{GREEN}+{formatted}{RESET}"
    elif cents < 0:
        return f"{RED}-{formatted}{RESET}"
    return formatted


# Paperless-ngx integration functions
def get_paperless_headers(config: dict) -> tuple:
    """Get base URL and auth headers for paperless API."""
    url = config.get("paperless_url")
    token = config.get("paperless_token")

    if not url or not token:
        raise ValueError("paperless_url and paperless_token must be configured")

    return url.rstrip("/"), {"Authorization": f"Token {token}"}


def verify_document_exists(doc_id: int, config: dict) -> bool:
    """Verify a document ID exists in paperless-ngx."""
    base_url, headers = get_paperless_headers(config)
    response = requests.get(f"{base_url}/api/documents/{doc_id}/", headers=headers)
    return response.status_code == 200


def upload_document_to_paperless(file_path: str, config: dict) -> int:
    """Upload a document to paperless-ngx and return the document ID."""
    base_url, headers = get_paperless_headers(config)

    # Upload document (returns task UUID)
    with open(file_path, "rb") as f:
        files = {"document": (Path(file_path).name, f)}
        response = requests.post(
            f"{base_url}/api/documents/post_document/", headers=headers, files=files
        )
    response.raise_for_status()
    task_id = response.text.strip('"')  # Returns UUID as quoted string

    # Poll for task completion to get document ID
    for _ in range(30):  # Max 30 seconds
        time.sleep(1)
        task_response = requests.get(
            f"{base_url}/api/tasks/?task_id={task_id}", headers=headers
        )
        task_response.raise_for_status()
        tasks = task_response.json()

        if tasks and tasks[0].get("status") == "SUCCESS":
            return tasks[0]["related_document"]
        elif tasks and tasks[0].get("status") == "FAILURE":
            raise RuntimeError(f"Document upload failed: {tasks[0].get('result')}")

    raise TimeoutError("Document upload timed out waiting for processing")


def resolve_doc_args(doc_args: list, config: dict) -> tuple:
    """
    Resolve --doc arguments to paperless document IDs.
    Returns: (successful_doc_ids, failed_args)
    - Integers are verified via API before adding
    - File paths are uploaded and the new document ID is returned
    - Failures are collected but don't stop processing
    """
    doc_ids = []
    failed = []

    for arg in doc_args:
        try:
            if arg.isdigit():
                doc_id = int(arg)
                print(f"Verifying document {doc_id}...")
                if verify_document_exists(doc_id, config):
                    doc_ids.append(doc_id)
                    print(f"  {GREEN}✓{RESET} Document {doc_id} exists")
                else:
                    print(f"  {RED}✗{RESET} Document {doc_id} not found in paperless")
                    failed.append(arg)
            elif Path(arg).exists():
                print(f"Uploading {arg} to paperless-ngx...")
                doc_id = upload_document_to_paperless(arg, config)
                print(f"  {GREEN}✓{RESET} Uploaded as document {doc_id}")
                doc_ids.append(doc_id)
            else:
                print(f"  {RED}✗{RESET} {arg} is not a valid ID or file path")
                failed.append(arg)
        except Exception as e:
            print(f"  {RED}✗{RESET} Failed: {e}")
            failed.append(arg)

    return doc_ids, failed


def insert_transaction_documents(cur, transaction_id: int, doc_ids: list):
    """Link paperless document IDs to a transaction."""
    for doc_id in doc_ids:
        cur.execute(
            "INSERT INTO transaction_document (transaction_id, paperless_id) VALUES (?, ?)",
            (transaction_id, doc_id),
        )


def check_paperless_connection(config: dict) -> tuple:
    """
    Check if paperless-ngx API is reachable and configured correctly.
    Returns: (success: bool, message: str, details: dict)
    """
    url = config.get("paperless_url")
    token = config.get("paperless_token")

    details = {
        "url_configured": bool(url),
        "token_configured": bool(token),
    }

    if not url:
        return False, "paperless_url not configured", details
    if not token:
        return False, "paperless_token not configured", details

    base_url = url.rstrip("/")
    headers = {"Authorization": f"Token {token}"}

    try:
        # Check API root
        response = requests.get(f"{base_url}/api/", headers=headers, timeout=10)
        details["status_code"] = response.status_code
        details["response_time_ms"] = int(response.elapsed.total_seconds() * 1000)

        if response.status_code == 200:
            # Try to get document count
            docs_response = requests.get(
                f"{base_url}/api/documents/", headers=headers, timeout=10
            )
            if docs_response.status_code == 200:
                data = docs_response.json()
                details["document_count"] = data.get("count", "unknown")
            return True, "Connection successful", details
        elif response.status_code == 401:
            return False, "Authentication failed - check your token", details
        elif response.status_code == 403:
            return False, "Access forbidden - check token permissions", details
        else:
            return False, f"Unexpected status code: {response.status_code}", details

    except requests.exceptions.ConnectionError:
        return False, f"Cannot connect to {base_url}", details
    except requests.exceptions.Timeout:
        return False, "Connection timed out", details
    except requests.exceptions.RequestException as e:
        return False, f"Request error: {e}", details


def get_or_prompt_account(cur, account_name=None):
    """Get account by name or prompt user to select one."""
    if account_name:
        cur.execute("SELECT id, name FROM account WHERE name = ?", (account_name,))
        result = cur.fetchone()
        if result:
            return result
        cur.execute(
            "SELECT id, name FROM account WHERE name LIKE ?", (f"%{account_name}%",)
        )
        results = cur.fetchall()
    else:
        cur.execute("SELECT id, name FROM account")
        results = cur.fetchall()

    if not results:
        print(f"{RED}No accounts found. Create one with: dv account add <name>{RESET}")
        return None

    if len(results) == 1:
        return results[0]

    print("Select an account:")
    for i, acc in enumerate(results):
        print(f"  {BOLD}{GREEN}{i + 1}{RESET}: {acc[1]} (ID: {acc[0]})")

    try:
        option = int(input("Account number: "))
        return results[option - 1]
    except (ValueError, IndexError):
        print(f"{RED}Invalid selection.{RESET}")
        return None


def get_or_prompt_company(cur, company_name):
    """Get company by name or prompt user to select one if multiple matches."""
    cur.execute(
        "SELECT id, isin, name FROM company WHERE name LIKE ?", (f"%{company_name}%",)
    )
    results = cur.fetchall()

    if not results:
        print(f"{RED}No company found matching '{company_name}'.{RESET}")
        return None

    if len(results) == 1:
        return results[0]

    print(f"Multiple companies match '{company_name}':")
    for i, com in enumerate(results):
        print(f"  {BOLD}{GREEN}{i + 1}{RESET}: {com[2]} (ISIN: {com[1]}, ID: {com[0]})")

    try:
        option = int(input("Which one? "))
        return results[option - 1]
    except (ValueError, IndexError):
        print(f"{RED}Invalid selection.{RESET}")
        return None


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
    parser_buy.add_argument("name", type=str, help="Company name")
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
    #                           Parse args
    # --------------------------------------------------------------------------
    args = parser.parse_args()

    # Load configuration
    config = load_config()

    # Handle config command (doesn't need database)
    if args.command == "config":
        if args.config_action == "show":
            print(f"{BOLD}Configuration:{RESET}")
            print(f"  Config file: {CONFIG_FILE}")
            for key, value in config.items():
                print(f"  {key}: {value}")
        elif args.config_action == "set":
            config[args.key] = args.value
            save_config(config)
            print(f"{GREEN}Set {args.key}={args.value}{RESET}")
        elif args.config_action == "check":
            print(f"{BOLD}Checking paperless-ngx connection...{RESET}\n")
            success, message, details = check_paperless_connection(config)

            # Show config status
            url_status = (
                f"{GREEN}✓{RESET}"
                if details.get("url_configured")
                else f"{RED}✗{RESET}"
            )
            token_status = (
                f"{GREEN}✓{RESET}"
                if details.get("token_configured")
                else f"{RED}✗{RESET}"
            )
            print(
                f"  {url_status} paperless_url: {config.get('paperless_url', '(not set)')}"
            )
            print(
                f"  {token_status} paperless_token: {'(configured)' if details.get('token_configured') else '(not set)'}"
            )

            # Show connection result
            if success:
                print(f"\n  {GREEN}✓ {message}{RESET}")
                if "response_time_ms" in details:
                    print(f"    Response time: {details['response_time_ms']}ms")
                if "document_count" in details:
                    print(f"    Documents in paperless: {details['document_count']}")
            else:
                print(f"\n  {RED}✗ {message}{RESET}")
                if not details.get("url_configured"):
                    print(
                        f"\n  Run: dv config set paperless_url http://your-server:8000"
                    )
                if not details.get("token_configured"):
                    print(f"  Run: dv config set paperless_token your-api-token")
        return

    # Determine database path (--db flag overrides config)
    db_path = args.db if args.db else config.get("db", DEFAULT_DB)

    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.execute("PRAGMA foreign_keys = ON;")

    # --------------------------------------------------------------------------
    #                           HANDLE: "account"
    # --------------------------------------------------------------------------
    if args.command == "account":
        if args.account_action == "add":
            try:
                cur.execute("INSERT INTO account (name) VALUES (?)", (args.name,))
                conn.commit()
                print(f"{GREEN}Account '{args.name}' created.{RESET}")
            except sqlite3.IntegrityError:
                print(f"{RED}Account '{args.name}' already exists.{RESET}")

        elif args.account_action == "list":
            cur.execute("SELECT id, name FROM account ORDER BY name")
            accounts = cur.fetchall()
            if not accounts:
                print("No accounts found.")
            else:
                print(f"{BOLD}Accounts:{RESET}")
                for acc in accounts:
                    print(f"  {acc[0]}: {acc[1]}")

    # --------------------------------------------------------------------------
    #                           HANDLE: "doc"
    # --------------------------------------------------------------------------
    elif args.command == "doc":
        if args.doc_action == "add":
            # Verify transaction exists
            cur.execute(
                'SELECT id, type, date FROM "transaction" WHERE id = ?',
                (args.transaction_id,),
            )
            transaction = cur.fetchone()
            if not transaction:
                print(f"{RED}Transaction {args.transaction_id} not found.{RESET}")
                conn.close()
                return

            # Resolve document arguments
            doc_ids, failed_docs = resolve_doc_args(args.docs, config)

            if doc_ids:
                # Check for duplicates
                cur.execute(
                    "SELECT paperless_id FROM transaction_document WHERE transaction_id = ?",
                    (args.transaction_id,),
                )
                existing = {row[0] for row in cur.fetchall()}
                new_docs = [d for d in doc_ids if d not in existing]
                duplicates = [d for d in doc_ids if d in existing]

                if duplicates:
                    print(
                        f"{YELLOW}Skipping already linked documents: {', '.join(str(d) for d in duplicates)}{RESET}"
                    )

                if new_docs:
                    insert_transaction_documents(cur, args.transaction_id, new_docs)
                    conn.commit()
                    print(
                        f"{GREEN}Linked {len(new_docs)} document(s) to transaction {args.transaction_id}.{RESET}"
                    )
                elif not duplicates:
                    print("No documents were linked.")
            else:
                print(f"{RED}No valid documents to link.{RESET}")

            if failed_docs:
                print(f"\n{YELLOW}Failed to process:{RESET}")
                for f in failed_docs:
                    print(f"  - {f}")

    # --------------------------------------------------------------------------
    #                           HANDLE: "list"
    # --------------------------------------------------------------------------
    elif args.command == "list":
        query = """
            SELECT
                t.id,
                a.name as account,
                t.type,
                c.name as company,
                t.quantity,
                t.unit_value,
                t.total_value,
                t.cost,
                t.date,
                t.linked_transaction,
                (SELECT GROUP_CONCAT(paperless_id) FROM transaction_document WHERE transaction_id = t.id) as doc_ids
            FROM "transaction" t
            JOIN account a ON t.account = a.id
            LEFT JOIN company c ON t.company = c.id
        """
        conditions = []
        params = []

        if args.account:
            conditions.append("a.name LIKE ?")
            params.append(f"%{args.account}%")
        if args.type:
            conditions.append("t.type = ?")
            params.append(args.type)

        if conditions:
            query += " WHERE " + " AND ".join(conditions)

        query += " ORDER BY t.date DESC, t.id DESC"

        cur.execute(query, params)
        transactions = cur.fetchall()

        if not transactions:
            print("No transactions found.")
        else:
            # Get paperless URL from config for document links
            paperless_url = config.get("paperless_url", "").rstrip("/")

            print(
                f"{BOLD}{'ID':<5} {'Date':<12} {'Account':<15} {'Type':<10} {'Company':<20} {'Qty':<6} {'Unit':<10} {'Total':<12} {'Cost':<8} {'Docs'}{RESET}"
            )
            print("-" * 115)
            for t in transactions:
                (
                    tid,
                    account,
                    ttype,
                    company,
                    qty,
                    unit,
                    total,
                    cost,
                    date,
                    linked,
                    doc_ids,
                ) = t
                company_str = company or "-"
                qty_str = str(qty) if qty else "-"
                unit_str = format_cents(unit) if unit else "-"
                total_str = format_cents(total) if total else "-"
                cost_str = format_cents(cost) if cost else "-"

                # Format document links
                if doc_ids and paperless_url:
                    doc_urls = ", ".join(
                        f"{paperless_url}/documents/{d}" for d in doc_ids.split(",")
                    )
                elif doc_ids:
                    doc_urls = doc_ids  # Just show IDs if no URL configured
                else:
                    doc_urls = "-"

                print(
                    f"{tid:<5} {date:<12} {account:<15} {ttype:<10} {company_str:<20} {qty_str:<6} {unit_str:<10} {total_str:<12} {cost_str:<8} {doc_urls}"
                )

    # --------------------------------------------------------------------------
    #                           HANDLE: "add"
    # --------------------------------------------------------------------------
    elif args.command == "add":
        # ----- BUY -----
        if args.transaction_type == "buy":
            account = get_or_prompt_account(cur, getattr(args, "account", None))
            if not account:
                conn.close()
                return

            company = get_or_prompt_company(cur, args.name)
            if not company:
                conn.close()
                return

            # Resolve document arguments
            doc_ids, failed_docs = [], []
            if args.doc:
                doc_ids, failed_docs = resolve_doc_args(args.doc, config)

            total_value = args.quantity * args.price
            date_str = (
                args.date.strftime("%Y-%m-%d")
                if isinstance(args.date, datetime)
                else args.date
            )

            print(f"\n{BOLD}Recording BUY transaction:{RESET}")
            print(f"  Account:  {account[1]}")
            print(f"  Company:  {company[2]}")
            print(f"  Quantity: {args.quantity}")
            print(f"  Price:    {format_cents(args.price)}")
            print(f"  Total:    {format_cents(total_value)}")
            print(f"  Cost:     {format_cents(args.cost)}")
            print(f"  Date:     {date_str}")
            if doc_ids:
                print(f"  Docs:     {', '.join(str(d) for d in doc_ids)}")

            if input("\nCommit? (y/N) ").lower() == "y":
                cur.execute(
                    """INSERT INTO "transaction"
                       (account, company, type, quantity, unit_value, total_value, cost, date)
                       VALUES (?, ?, 'buy', ?, ?, ?, ?, ?)""",
                    (
                        account[0],
                        company[0],
                        args.quantity,
                        args.price,
                        total_value,
                        args.cost,
                        date_str,
                    ),
                )
                conn.commit()
                transaction_id = cur.lastrowid
                print(f"{GREEN}Transaction recorded (ID: {transaction_id}).{RESET}")

                # Link documents
                if doc_ids:
                    insert_transaction_documents(cur, transaction_id, doc_ids)
                    conn.commit()
                    print(
                        f"Linked {len(doc_ids)} document(s) to transaction {transaction_id}"
                    )

                if failed_docs:
                    print(
                        f"\n{YELLOW}Warning: {len(failed_docs)} document(s) could not be linked:{RESET}"
                    )
                    for f in failed_docs:
                        print(f"  - {f}")
                    print("\nTo attach manually later, use:")
                    print(f"  dv doc add {transaction_id} <paperless_doc_id>")

        # ----- SELL -----
        elif args.transaction_type == "sell":
            account = get_or_prompt_account(cur, getattr(args, "account", None))
            if not account:
                conn.close()
                return

            company = get_or_prompt_company(cur, args.name)
            if not company:
                conn.close()
                return

            # Resolve document arguments
            doc_ids, failed_docs = [], []
            if args.doc:
                doc_ids, failed_docs = resolve_doc_args(args.doc, config)

            total_value = args.quantity * args.price
            date_str = (
                args.date.strftime("%Y-%m-%d")
                if isinstance(args.date, datetime)
                else args.date
            )

            print(f"\n{BOLD}Recording SELL transaction:{RESET}")
            print(f"  Account:  {account[1]}")
            print(f"  Company:  {company[2]}")
            print(f"  Quantity: {args.quantity}")
            print(f"  Price:    {format_cents(args.price)}")
            print(f"  Total:    {format_cents(total_value)}")
            print(f"  Cost:     {format_cents(args.cost)}")
            print(f"  Date:     {date_str}")
            if doc_ids:
                print(f"  Docs:     {', '.join(str(d) for d in doc_ids)}")

            if input("\nCommit? (y/N) ").lower() == "y":
                cur.execute(
                    """INSERT INTO "transaction"
                       (account, company, type, quantity, unit_value, total_value, cost, date)
                       VALUES (?, ?, 'sell', ?, ?, ?, ?, ?)""",
                    (
                        account[0],
                        company[0],
                        args.quantity,
                        args.price,
                        total_value,
                        args.cost,
                        date_str,
                    ),
                )
                conn.commit()
                transaction_id = cur.lastrowid
                print(f"{GREEN}Transaction recorded (ID: {transaction_id}).{RESET}")

                # Link documents
                if doc_ids:
                    insert_transaction_documents(cur, transaction_id, doc_ids)
                    conn.commit()
                    print(
                        f"Linked {len(doc_ids)} document(s) to transaction {transaction_id}"
                    )

                if failed_docs:
                    print(
                        f"\n{YELLOW}Warning: {len(failed_docs)} document(s) could not be linked:{RESET}"
                    )
                    for f in failed_docs:
                        print(f"  - {f}")
                    print("\nTo attach manually later, use:")
                    print(f"  dv doc add {transaction_id} <paperless_doc_id>")

        # ----- DIVIDEND -----
        elif args.transaction_type == "dividend":
            account = get_or_prompt_account(cur, getattr(args, "account", None))
            if not account:
                conn.close()
                return

            company = get_or_prompt_company(cur, args.name)
            if not company:
                conn.close()
                return

            # Resolve document arguments
            doc_ids, failed_docs = [], []
            if args.doc:
                doc_ids, failed_docs = resolve_doc_args(args.doc, config)

            date_str = (
                args.date.strftime("%Y-%m-%d")
                if isinstance(args.date, datetime)
                else args.date
            )

            print(f"\n{BOLD}Recording DIVIDEND transaction:{RESET}")
            print(f"  Account:  {account[1]}")
            print(f"  Company:  {company[2]}")
            print(f"  Amount:   {format_cents(args.amount)}")
            print(f"  Cost:     {format_cents(args.cost)}")
            print(f"  Date:     {date_str}")
            if doc_ids:
                print(f"  Docs:     {', '.join(str(d) for d in doc_ids)}")

            if input("\nCommit? (y/N) ").lower() == "y":
                cur.execute(
                    """INSERT INTO "transaction"
                       (account, company, type, total_value, cost, date)
                       VALUES (?, ?, 'dividend', ?, ?, ?)""",
                    (account[0], company[0], args.amount, args.cost, date_str),
                )
                conn.commit()
                transaction_id = cur.lastrowid
                print(f"{GREEN}Transaction recorded (ID: {transaction_id}).{RESET}")

                # Link documents
                if doc_ids:
                    insert_transaction_documents(cur, transaction_id, doc_ids)
                    conn.commit()
                    print(
                        f"Linked {len(doc_ids)} document(s) to transaction {transaction_id}"
                    )

                if failed_docs:
                    print(
                        f"\n{YELLOW}Warning: {len(failed_docs)} document(s) could not be linked:{RESET}"
                    )
                    for f in failed_docs:
                        print(f"  - {f}")
                    print("\nTo attach manually later, use:")
                    print(f"  dv doc add {transaction_id} <paperless_doc_id>")

        # ----- INTEREST -----
        elif args.transaction_type == "interest":
            account = get_or_prompt_account(cur, getattr(args, "account", None))
            if not account:
                conn.close()
                return

            # Resolve document arguments
            doc_ids, failed_docs = [], []
            if args.doc:
                doc_ids, failed_docs = resolve_doc_args(args.doc, config)

            date_str = (
                args.date.strftime("%Y-%m-%d")
                if isinstance(args.date, datetime)
                else args.date
            )

            print(f"\n{BOLD}Recording INTEREST transaction:{RESET}")
            print(f"  Account:  {account[1]}")
            print(f"  Amount:   {format_cents(args.amount)}")
            print(f"  Cost:     {format_cents(args.cost)}")
            print(f"  Date:     {date_str}")
            if doc_ids:
                print(f"  Docs:     {', '.join(str(d) for d in doc_ids)}")

            if input("\nCommit? (y/N) ").lower() == "y":
                cur.execute(
                    """INSERT INTO "transaction"
                       (account, type, total_value, cost, date)
                       VALUES (?, 'interest', ?, ?, ?)""",
                    (account[0], args.amount, args.cost, date_str),
                )
                conn.commit()
                transaction_id = cur.lastrowid
                print(f"{GREEN}Transaction recorded (ID: {transaction_id}).{RESET}")

                # Link documents
                if doc_ids:
                    insert_transaction_documents(cur, transaction_id, doc_ids)
                    conn.commit()
                    print(
                        f"Linked {len(doc_ids)} document(s) to transaction {transaction_id}"
                    )

                if failed_docs:
                    print(
                        f"\n{YELLOW}Warning: {len(failed_docs)} document(s) could not be linked:{RESET}"
                    )
                    for f in failed_docs:
                        print(f"  - {f}")
                    print("\nTo attach manually later, use:")
                    print(f"  dv doc add {transaction_id} <paperless_doc_id>")

        # ----- DEPOSIT -----
        elif args.transaction_type == "deposit":
            account = get_or_prompt_account(cur, getattr(args, "account", None))
            if not account:
                conn.close()
                return

            # Resolve document arguments
            doc_ids, failed_docs = [], []
            if args.doc:
                doc_ids, failed_docs = resolve_doc_args(args.doc, config)

            date_str = (
                args.date.strftime("%Y-%m-%d")
                if isinstance(args.date, datetime)
                else args.date
            )

            print(f"\n{BOLD}Recording DEPOSIT transaction:{RESET}")
            print(f"  Account:  {account[1]}")
            print(f"  Amount:   {format_cents(args.amount)}")
            print(f"  Cost:     {format_cents(args.cost)}")
            print(f"  Date:     {date_str}")
            if doc_ids:
                print(f"  Docs:     {', '.join(str(d) for d in doc_ids)}")

            if input("\nCommit? (y/N) ").lower() == "y":
                cur.execute(
                    """INSERT INTO "transaction"
                       (account, type, total_value, cost, date)
                       VALUES (?, 'deposit', ?, ?, ?)""",
                    (account[0], args.amount, args.cost, date_str),
                )
                conn.commit()
                transaction_id = cur.lastrowid
                print(f"{GREEN}Transaction recorded (ID: {transaction_id}).{RESET}")

                # Link documents
                if doc_ids:
                    insert_transaction_documents(cur, transaction_id, doc_ids)
                    conn.commit()
                    print(
                        f"Linked {len(doc_ids)} document(s) to transaction {transaction_id}"
                    )

                if failed_docs:
                    print(
                        f"\n{YELLOW}Warning: {len(failed_docs)} document(s) could not be linked:{RESET}"
                    )
                    for f in failed_docs:
                        print(f"  - {f}")
                    print("\nTo attach manually later, use:")
                    print(f"  dv doc add {transaction_id} <paperless_doc_id>")

        # ----- WITHDRAWAL -----
        elif args.transaction_type == "withdrawal":
            account = get_or_prompt_account(cur, getattr(args, "account", None))
            if not account:
                conn.close()
                return

            # Resolve document arguments
            doc_ids, failed_docs = [], []
            if args.doc:
                doc_ids, failed_docs = resolve_doc_args(args.doc, config)

            date_str = (
                args.date.strftime("%Y-%m-%d")
                if isinstance(args.date, datetime)
                else args.date
            )

            print(f"\n{BOLD}Recording WITHDRAWAL transaction:{RESET}")
            print(f"  Account:  {account[1]}")
            print(f"  Amount:   {format_cents(args.amount)}")
            print(f"  Cost:     {format_cents(args.cost)}")
            print(f"  Date:     {date_str}")
            if doc_ids:
                print(f"  Docs:     {', '.join(str(d) for d in doc_ids)}")

            if input("\nCommit? (y/N) ").lower() == "y":
                cur.execute(
                    """INSERT INTO "transaction"
                       (account, type, total_value, cost, date)
                       VALUES (?, 'withdrawal', ?, ?, ?)""",
                    (account[0], args.amount, args.cost, date_str),
                )
                conn.commit()
                transaction_id = cur.lastrowid
                print(f"{GREEN}Transaction recorded (ID: {transaction_id}).{RESET}")

                # Link documents
                if doc_ids:
                    insert_transaction_documents(cur, transaction_id, doc_ids)
                    conn.commit()
                    print(
                        f"Linked {len(doc_ids)} document(s) to transaction {transaction_id}"
                    )

                if failed_docs:
                    print(
                        f"\n{YELLOW}Warning: {len(failed_docs)} document(s) could not be linked:{RESET}"
                    )
                    for f in failed_docs:
                        print(f"  - {f}")
                    print("\nTo attach manually later, use:")
                    print(f"  dv doc add {transaction_id} <paperless_doc_id>")

        # ----- TRANSFER -----
        elif args.transaction_type == "transfer":
            # Get source account
            cur.execute(
                "SELECT id, name FROM account WHERE name LIKE ?",
                (f"%{args.from_account}%",),
            )
            from_results = cur.fetchall()
            if not from_results:
                print(f"{RED}Source account '{args.from_account}' not found.{RESET}")
                conn.close()
                return
            if len(from_results) > 1:
                print(f"Multiple source accounts match '{args.from_account}':")
                for i, acc in enumerate(from_results):
                    print(f"  {i + 1}: {acc[1]}")
                try:
                    from_account = from_results[int(input("Select source: ")) - 1]
                except (ValueError, IndexError):
                    print(f"{RED}Invalid selection.{RESET}")
                    conn.close()
                    return
            else:
                from_account = from_results[0]

            # Get destination account
            cur.execute(
                "SELECT id, name FROM account WHERE name LIKE ?",
                (f"%{args.to_account}%",),
            )
            to_results = cur.fetchall()
            if not to_results:
                print(f"{RED}Destination account '{args.to_account}' not found.{RESET}")
                conn.close()
                return
            if len(to_results) > 1:
                print(f"Multiple destination accounts match '{args.to_account}':")
                for i, acc in enumerate(to_results):
                    print(f"  {i + 1}: {acc[1]}")
                try:
                    to_account = to_results[int(input("Select destination: ")) - 1]
                except (ValueError, IndexError):
                    print(f"{RED}Invalid selection.{RESET}")
                    conn.close()
                    return
            else:
                to_account = to_results[0]

            if from_account[0] == to_account[0]:
                print(f"{RED}Source and destination accounts must be different.{RESET}")
                conn.close()
                return

            # Resolve document arguments
            doc_ids, failed_docs = [], []
            if args.doc:
                doc_ids, failed_docs = resolve_doc_args(args.doc, config)

            date_str = (
                args.date.strftime("%Y-%m-%d")
                if isinstance(args.date, datetime)
                else args.date
            )

            print(f"\n{BOLD}Recording TRANSFER transaction:{RESET}")
            print(f"  From:     {from_account[1]}")
            print(f"  To:       {to_account[1]}")
            print(f"  Amount:   {format_cents(args.amount)}")
            print(f"  Cost:     {format_cents(args.cost)}")
            print(f"  Date:     {date_str}")
            if doc_ids:
                print(f"  Docs:     {', '.join(str(d) for d in doc_ids)}")

            if input("\nCommit? (y/N) ").lower() == "y":
                # Insert outgoing transfer (from source account)
                cur.execute(
                    """INSERT INTO "transaction"
                       (account, type, total_value, cost, date)
                       VALUES (?, 'transfer', ?, ?, ?)""",
                    (from_account[0], -args.amount, args.cost, date_str),
                )
                outgoing_id = cur.lastrowid

                # Insert incoming transfer (to destination account)
                cur.execute(
                    """INSERT INTO "transaction"
                       (account, type, total_value, cost, date, linked_transaction)
                       VALUES (?, 'transfer', ?, 0, ?, ?)""",
                    (to_account[0], args.amount, date_str, outgoing_id),
                )
                incoming_id = cur.lastrowid

                # Link the outgoing transaction to the incoming one
                cur.execute(
                    """UPDATE "transaction" SET linked_transaction = ? WHERE id = ?""",
                    (incoming_id, outgoing_id),
                )

                conn.commit()
                print(
                    f"{GREEN}Transfer recorded (IDs: {outgoing_id} <-> {incoming_id}).{RESET}"
                )

                # Link documents to the outgoing transaction
                if doc_ids:
                    insert_transaction_documents(cur, outgoing_id, doc_ids)
                    conn.commit()
                    print(
                        f"Linked {len(doc_ids)} document(s) to transaction {outgoing_id}"
                    )

                if failed_docs:
                    print(
                        f"\n{YELLOW}Warning: {len(failed_docs)} document(s) could not be linked:{RESET}"
                    )
                    for f in failed_docs:
                        print(f"  - {f}")
                    print("\nTo attach manually later, use:")
                    print(f"  dv doc add {outgoing_id} <paperless_doc_id>")

    # --------------------------------------------------------------------------
    #                           HANDLE: "report"
    # --------------------------------------------------------------------------
    elif args.command == "report":
        # Build date filter
        date_conditions = []
        date_params = []
        if args.from_date:
            date_conditions.append("t.date >= ?")
            date_params.append(args.from_date.strftime("%Y-%m-%d"))
        if args.to_date:
            date_conditions.append("t.date <= ?")
            date_params.append(args.to_date.strftime("%Y-%m-%d"))
        date_filter = " AND ".join(date_conditions) if date_conditions else "1=1"

        # Build account filter
        account_filter = "1=1"
        account_params = []
        if args.account:
            account_filter = "a.name LIKE ?"
            account_params = [f"%{args.account}%"]

        # ----- BALANCE REPORT -----
        if args.report_type == "balance":
            query = f"""
                SELECT
                    a.name,
                    COALESCE(SUM(CASE
                        WHEN t.type = 'deposit' THEN t.total_value
                        WHEN t.type = 'withdrawal' THEN -t.total_value
                        WHEN t.type = 'interest' THEN t.total_value
                        WHEN t.type = 'dividend' THEN t.total_value
                        WHEN t.type = 'buy' THEN -t.total_value
                        WHEN t.type = 'sell' THEN t.total_value
                        WHEN t.type = 'transfer' THEN t.total_value
                        ELSE 0
                    END), 0) as cash_balance,
                    COALESCE(SUM(CASE WHEN t.cost IS NOT NULL THEN -t.cost ELSE 0 END), 0) as total_fees
                FROM account a
                LEFT JOIN "transaction" t ON a.id = t.account AND {date_filter}
                WHERE {account_filter}
                GROUP BY a.id, a.name
                ORDER BY a.name
            """
            cur.execute(query, date_params + account_params)
            results = cur.fetchall()

            print(f"\n{BOLD}Account Balances:{RESET}")
            print("-" * 50)
            total_balance = 0
            total_fees = 0
            for name, balance, fees in results:
                net = balance + fees
                total_balance += balance
                total_fees += fees
                print(
                    f"  {name:<20} {format_cents(net):>15}  (fees: {format_cents(abs(fees))})"
                )
            print("-" * 50)
            print(
                f"  {'TOTAL':<20} {format_cents(total_balance + total_fees):>15}  (fees: {format_cents(abs(total_fees))})"
            )

        # ----- CASHFLOW REPORT -----
        elif args.report_type == "cashflow":
            query = f"""
                SELECT
                    a.name,
                    COALESCE(SUM(CASE WHEN t.type = 'deposit' THEN t.total_value ELSE 0 END), 0) as deposits,
                    COALESCE(SUM(CASE WHEN t.type = 'withdrawal' THEN t.total_value ELSE 0 END), 0) as withdrawals,
                    COALESCE(SUM(CASE WHEN t.type = 'dividend' THEN t.total_value ELSE 0 END), 0) as dividends,
                    COALESCE(SUM(CASE WHEN t.type = 'interest' THEN t.total_value ELSE 0 END), 0) as interest,
                    COALESCE(SUM(CASE WHEN t.cost IS NOT NULL THEN t.cost ELSE 0 END), 0) as fees
                FROM account a
                LEFT JOIN "transaction" t ON a.id = t.account AND {date_filter}
                WHERE {account_filter}
                GROUP BY a.id, a.name
                ORDER BY a.name
            """
            cur.execute(query, date_params + account_params)
            results = cur.fetchall()

            print(f"\n{BOLD}Cash Flow Report:{RESET}")
            print(
                f"{'Account':<20} {'Deposits':>12} {'Withdrawals':>12} {'Dividends':>12} {'Interest':>12} {'Fees':>12} {'Net':>12}"
            )
            print("-" * 92)

            totals = [0, 0, 0, 0, 0]
            for name, deposits, withdrawals, dividends, interest, fees in results:
                net = deposits - withdrawals + dividends + interest - fees
                totals[0] += deposits
                totals[1] += withdrawals
                totals[2] += dividends
                totals[3] += interest
                totals[4] += fees
                print(
                    f"{name:<20} {format_cents(deposits):>12} {format_cents(withdrawals):>12} {format_cents(dividends):>12} {format_cents(interest):>12} {format_cents(fees):>12} {format_cents(net):>12}"
                )

            print("-" * 92)
            net_total = totals[0] - totals[1] + totals[2] + totals[3] - totals[4]
            print(
                f"{'TOTAL':<20} {format_cents(totals[0]):>12} {format_cents(totals[1]):>12} {format_cents(totals[2]):>12} {format_cents(totals[3]):>12} {format_cents(totals[4]):>12} {format_cents(net_total):>12}"
            )

        # ----- HOLDINGS REPORT -----
        elif args.report_type == "holdings":
            query = f"""
                SELECT
                    a.name as account,
                    c.name as company,
                    SUM(CASE WHEN t.type = 'buy' THEN t.quantity ELSE 0 END) as bought,
                    SUM(CASE WHEN t.type = 'sell' THEN t.quantity ELSE 0 END) as sold,
                    SUM(CASE WHEN t.type = 'buy' THEN t.total_value ELSE 0 END) as total_cost,
                    SUM(CASE WHEN t.type = 'sell' THEN t.total_value ELSE 0 END) as total_proceeds
                FROM "transaction" t
                JOIN account a ON t.account = a.id
                JOIN company c ON t.company = c.id
                WHERE t.type IN ('buy', 'sell') AND {date_filter} AND {account_filter}
                GROUP BY a.id, c.id
                HAVING (bought - sold) > 0
                ORDER BY a.name, c.name
            """
            cur.execute(query, date_params + account_params)
            results = cur.fetchall()

            if not results:
                print("\nNo holdings found.")
            else:
                print(f"\n{BOLD}Portfolio Holdings:{RESET}")
                print(
                    f"{'Account':<20} {'Company':<25} {'Shares':>8} {'Avg Cost':>12} {'Total Cost':>14}"
                )
                print("-" * 85)

                current_account = None
                for (
                    account,
                    company,
                    bought,
                    sold,
                    total_cost,
                    total_proceeds,
                ) in results:
                    shares = bought - sold
                    if shares > 0:
                        # Calculate average cost (cost basis of remaining shares)
                        avg_cost = total_cost // bought if bought > 0 else 0
                        remaining_cost = avg_cost * shares

                        if account != current_account:
                            if current_account is not None:
                                print()
                            current_account = account

                        print(
                            f"{account:<20} {company:<25} {shares:>8} {format_cents(avg_cost):>12} {format_cents(remaining_cost):>14}"
                        )

        # ----- PERFORMANCE REPORT -----
        elif args.report_type == "performance":
            # Get realized gains/losses per company
            query = f"""
                SELECT
                    c.name as company,
                    SUM(CASE WHEN t.type = 'buy' THEN t.quantity ELSE 0 END) as total_bought,
                    SUM(CASE WHEN t.type = 'sell' THEN t.quantity ELSE 0 END) as total_sold,
                    SUM(CASE WHEN t.type = 'buy' THEN t.total_value ELSE 0 END) as buy_value,
                    SUM(CASE WHEN t.type = 'sell' THEN t.total_value ELSE 0 END) as sell_value,
                    SUM(CASE WHEN t.type = 'dividend' THEN t.total_value ELSE 0 END) as dividends,
                    SUM(COALESCE(t.cost, 0)) as fees
                FROM "transaction" t
                JOIN account a ON t.account = a.id
                JOIN company c ON t.company = c.id
                WHERE t.type IN ('buy', 'sell', 'dividend') AND {date_filter} AND {account_filter}
                GROUP BY c.id
                ORDER BY c.name
            """
            cur.execute(query, date_params + account_params)
            results = cur.fetchall()

            if not results:
                print("\nNo investment transactions found.")
            else:
                print(f"\n{BOLD}Investment Performance:{RESET}")
                print(
                    f"{'Company':<25} {'Bought':>8} {'Sold':>8} {'Buy Value':>12} {'Sell Value':>12} {'Realized G/L':>14} {'Dividends':>12}"
                )
                print("-" * 105)

                total_realized = 0
                total_dividends = 0
                total_fees = 0

                for (
                    company,
                    bought,
                    sold,
                    buy_value,
                    sell_value,
                    dividends,
                    fees,
                ) in results:
                    # Calculate realized gain/loss using average cost method
                    if bought > 0 and sold > 0:
                        avg_cost_per_share = buy_value // bought
                        cost_basis_sold = avg_cost_per_share * sold
                        realized_gain = sell_value - cost_basis_sold
                    else:
                        realized_gain = 0

                    total_realized += realized_gain
                    total_dividends += dividends
                    total_fees += fees

                    realized_str = format_cents_colored(realized_gain)
                    print(
                        f"{company:<25} {bought:>8} {sold:>8} {format_cents(buy_value):>12} {format_cents(sell_value):>12} {realized_str:>23} {format_cents(dividends):>12}"
                    )

                print("-" * 105)
                print(
                    f"\n  {BOLD}Realized Gains/Losses:{RESET}  {format_cents_colored(total_realized)}"
                )
                print(
                    f"  {BOLD}Total Dividends:{RESET}        {format_cents(total_dividends)}"
                )
                print(
                    f"  {BOLD}Total Fees:{RESET}             {format_cents(total_fees)}"
                )
                print(
                    f"  {BOLD}Net Return:{RESET}             {format_cents_colored(total_realized + total_dividends - total_fees)}"
                )
                print(
                    f"\n  {YELLOW}Note: Unrealized gains/losses require current market prices (not yet implemented){RESET}"
                )

        # ----- SUMMARY REPORT -----
        elif args.report_type == "summary":
            print(
                f"\n{BOLD}═══════════════════════════════════════════════════════════════{RESET}"
            )
            print(f"{BOLD}                     INVESTMENT SUMMARY{RESET}")
            print(
                f"{BOLD}═══════════════════════════════════════════════════════════════{RESET}"
            )

            # Cash balances
            query = f"""
                SELECT
                    COALESCE(SUM(CASE
                        WHEN t.type = 'deposit' THEN t.total_value
                        WHEN t.type = 'withdrawal' THEN -t.total_value
                        WHEN t.type = 'interest' THEN t.total_value
                        WHEN t.type = 'dividend' THEN t.total_value
                        WHEN t.type = 'buy' THEN -t.total_value
                        WHEN t.type = 'sell' THEN t.total_value
                        WHEN t.type = 'transfer' THEN t.total_value
                        ELSE 0
                    END), 0) as cash_balance,
                    COALESCE(SUM(CASE WHEN t.cost IS NOT NULL THEN t.cost ELSE 0 END), 0) as total_fees
                FROM account a
                LEFT JOIN "transaction" t ON a.id = t.account AND {date_filter}
                WHERE {account_filter}
            """
            cur.execute(query, date_params + account_params)
            cash_balance, total_fees = cur.fetchone()

            # Cash flow totals
            query = f"""
                SELECT
                    COALESCE(SUM(CASE WHEN t.type = 'deposit' THEN t.total_value ELSE 0 END), 0) as deposits,
                    COALESCE(SUM(CASE WHEN t.type = 'withdrawal' THEN t.total_value ELSE 0 END), 0) as withdrawals,
                    COALESCE(SUM(CASE WHEN t.type = 'dividend' THEN t.total_value ELSE 0 END), 0) as dividends,
                    COALESCE(SUM(CASE WHEN t.type = 'interest' THEN t.total_value ELSE 0 END), 0) as interest
                FROM account a
                LEFT JOIN "transaction" t ON a.id = t.account AND {date_filter}
                WHERE {account_filter}
            """
            cur.execute(query, date_params + account_params)
            deposits, withdrawals, dividends, interest = cur.fetchone()

            # Holdings value (at cost)
            query = f"""
                SELECT
                    SUM(CASE WHEN t.type = 'buy' THEN t.quantity ELSE -t.quantity END) as shares,
                    SUM(CASE WHEN t.type = 'buy' THEN t.total_value ELSE 0 END) as buy_total,
                    SUM(CASE WHEN t.type = 'buy' THEN t.quantity ELSE 0 END) as bought_qty
                FROM "transaction" t
                JOIN account a ON t.account = a.id
                WHERE t.type IN ('buy', 'sell') AND {date_filter} AND {account_filter}
            """
            cur.execute(query, date_params + account_params)
            row = cur.fetchone()
            total_shares = row[0] or 0
            buy_total = row[1] or 0
            bought_qty = row[2] or 1

            # Calculate holdings at cost
            avg_cost = buy_total // bought_qty if bought_qty > 0 else 0
            holdings_at_cost = avg_cost * total_shares if total_shares > 0 else 0

            # Realized gains
            query = f"""
                SELECT
                    c.id,
                    SUM(CASE WHEN t.type = 'buy' THEN t.quantity ELSE 0 END) as bought,
                    SUM(CASE WHEN t.type = 'sell' THEN t.quantity ELSE 0 END) as sold,
                    SUM(CASE WHEN t.type = 'buy' THEN t.total_value ELSE 0 END) as buy_value,
                    SUM(CASE WHEN t.type = 'sell' THEN t.total_value ELSE 0 END) as sell_value
                FROM "transaction" t
                JOIN account a ON t.account = a.id
                JOIN company c ON t.company = c.id
                WHERE t.type IN ('buy', 'sell') AND {date_filter} AND {account_filter}
                GROUP BY c.id
            """
            cur.execute(query, date_params + account_params)
            realized_total = 0
            for _, bought, sold, buy_value, sell_value in cur.fetchall():
                if bought > 0 and sold > 0:
                    avg_cost_share = buy_value // bought
                    cost_basis = avg_cost_share * sold
                    realized_total += sell_value - cost_basis

            net_contributions = deposits - withdrawals
            income = dividends + interest

            print(f"\n  {BOLD}Cash Flow:{RESET}")
            print(f"    Deposits:              {format_cents(deposits):>14}")
            print(f"    Withdrawals:           {format_cents(withdrawals):>14}")
            print(f"    Net Contributions:     {format_cents(net_contributions):>14}")

            print(f"\n  {BOLD}Income:{RESET}")
            print(f"    Dividends:             {format_cents(dividends):>14}")
            print(f"    Interest:              {format_cents(interest):>14}")
            print(f"    Total Income:          {format_cents(income):>14}")

            print(f"\n  {BOLD}Performance:{RESET}")
            print(
                f"    Realized Gains/Losses: {format_cents_colored(realized_total):>23}"
            )
            print(f"    Unrealized G/L:        {YELLOW}{'(needs prices)':>14}{RESET}")

            print(f"\n  {BOLD}Current Position:{RESET}")
            print(
                f"    Cash Balance:          {format_cents(cash_balance - total_fees):>14}"
            )
            print(f"    Holdings (at cost):    {format_cents(holdings_at_cost):>14}")
            print(f"    Total Fees Paid:       {format_cents(total_fees):>14}")

            total_value = cash_balance - total_fees + holdings_at_cost
            print(
                f"\n  {BOLD}Total Portfolio Value:     {format_cents(total_value):>14}{RESET}"
            )
            print(
                f"{BOLD}═══════════════════════════════════════════════════════════════{RESET}\n"
            )

    conn.close()


if __name__ == "__main__":
    main()
