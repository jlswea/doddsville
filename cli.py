import argparse
import sqlite3
from datetime import datetime


# ANSI escape codes
RESET = "\033[0m"
BOLD = "\033[1m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
BLUE = "\033[34m"


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


def get_or_prompt_account(cur, account_name=None):
    """Get account by name or prompt user to select one."""
    if account_name:
        cur.execute("SELECT id, name FROM account WHERE name = ?", (account_name,))
        result = cur.fetchone()
        if result:
            return result
        cur.execute("SELECT id, name FROM account WHERE name LIKE ?", (f"%{account_name}%",))
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

    parser_account = main_commands.add_parser(
        "account", help="Manage accounts"
    )
    account_subcommands = parser_account.add_subparsers(
        dest="account_action", required=True, help="Account commands"
    )

    # --- "account add" sub-command ---
    parser_account_add = account_subcommands.add_parser(
        "add", help="Add a new account"
    )
    parser_account_add.add_argument("name", type=str, help="Account name")

    # --- "account list" sub-command ---
    account_subcommands.add_parser("list", help="List all accounts")

    # --------------------------------------------------------------------------
    #                           COMMAND: "list"
    # --------------------------------------------------------------------------

    parser_list = main_commands.add_parser(
        "list", help="List all recorded transactions."
    )
    parser_list.add_argument(
        "--account", "-a", type=str, help="Filter by account name"
    )
    parser_list.add_argument(
        "--type", "-t", type=str, help="Filter by transaction type"
    )

    # --------------------------------------------------------------------------
    #                           COMMAND: "add"
    # --------------------------------------------------------------------------

    parser_add = main_commands.add_parser(
        "add", help="Add a new transaction."
    )

    add_transaction_types = parser_add.add_subparsers(
        dest="transaction_type", required=True, help="Type of transaction to add"
    )

    # Common arguments for transactions that need an account
    def add_common_args(p, needs_company=False):
        p.add_argument("--account", "-a", type=str, help="Account name")
        p.add_argument(
            "--date", "-d",
            type=validate_date_format,
            default=datetime.now().strftime("%d.%m.%Y"),
            help="Transaction date (DD.MM.YYYY)",
        )
        p.add_argument(
            "--cost", "-c",
            type=cents_from_decimal_string,
            default=0,
            help="Fees/costs in euros (e.g., 1.50)",
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
    parser_sell = add_transaction_types.add_parser(
        "sell", help="Record a stock sale."
    )
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
        "amount", type=cents_from_decimal_string, help="Total dividend amount (e.g., 50.00)"
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
        "amount", type=cents_from_decimal_string, help="Withdrawal amount (e.g., 500.00)"
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
        "--date", "-d",
        type=validate_date_format,
        default=datetime.now().strftime("%d.%m.%Y"),
        help="Transaction date (DD.MM.YYYY)",
    )
    parser_transfer.add_argument(
        "--cost", "-c",
        type=cents_from_decimal_string,
        default=0,
        help="Transfer fees (e.g., 0.50)",
    )

    # --- "--version, -v" ---
    parser.add_argument(
        "-v",
        "--version",
        action="version",
        version="doddsville@0.0.2",
        help="The installed version of the doddsville CLI",
    )

    # --------------------------------------------------------------------------
    #                           Parse args
    # --------------------------------------------------------------------------
    args = parser.parse_args()

    conn = sqlite3.connect("data.db")
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
                t.linked_transaction
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
            print(f"{BOLD}{'ID':<5} {'Date':<12} {'Account':<15} {'Type':<10} {'Company':<20} {'Qty':<6} {'Unit':<10} {'Total':<12} {'Cost':<8}{RESET}")
            print("-" * 100)
            for t in transactions:
                tid, account, ttype, company, qty, unit, total, cost, date, linked = t
                company_str = company or "-"
                qty_str = str(qty) if qty else "-"
                unit_str = format_cents(unit) if unit else "-"
                total_str = format_cents(total) if total else "-"
                cost_str = format_cents(cost) if cost else "-"
                print(f"{tid:<5} {date:<12} {account:<15} {ttype:<10} {company_str:<20} {qty_str:<6} {unit_str:<10} {total_str:<12} {cost_str:<8}")

    # --------------------------------------------------------------------------
    #                           HANDLE: "add"
    # --------------------------------------------------------------------------
    elif args.command == "add":
        # ----- BUY -----
        if args.transaction_type == "buy":
            account = get_or_prompt_account(cur, getattr(args, 'account', None))
            if not account:
                conn.close()
                return

            company = get_or_prompt_company(cur, args.name)
            if not company:
                conn.close()
                return

            total_value = args.quantity * args.price
            date_str = args.date.strftime("%Y-%m-%d") if isinstance(args.date, datetime) else args.date

            print(f"\n{BOLD}Recording BUY transaction:{RESET}")
            print(f"  Account:  {account[1]}")
            print(f"  Company:  {company[2]}")
            print(f"  Quantity: {args.quantity}")
            print(f"  Price:    {format_cents(args.price)}")
            print(f"  Total:    {format_cents(total_value)}")
            print(f"  Cost:     {format_cents(args.cost)}")
            print(f"  Date:     {date_str}")

            if input("\nCommit? (y/N) ").lower() == "y":
                cur.execute(
                    """INSERT INTO "transaction"
                       (account, company, type, quantity, unit_value, total_value, cost, date)
                       VALUES (?, ?, 'buy', ?, ?, ?, ?, ?)""",
                    (account[0], company[0], args.quantity, args.price, total_value, args.cost, date_str)
                )
                conn.commit()
                print(f"{GREEN}Transaction recorded.{RESET}")

        # ----- SELL -----
        elif args.transaction_type == "sell":
            account = get_or_prompt_account(cur, getattr(args, 'account', None))
            if not account:
                conn.close()
                return

            company = get_or_prompt_company(cur, args.name)
            if not company:
                conn.close()
                return

            total_value = args.quantity * args.price
            date_str = args.date.strftime("%Y-%m-%d") if isinstance(args.date, datetime) else args.date

            print(f"\n{BOLD}Recording SELL transaction:{RESET}")
            print(f"  Account:  {account[1]}")
            print(f"  Company:  {company[2]}")
            print(f"  Quantity: {args.quantity}")
            print(f"  Price:    {format_cents(args.price)}")
            print(f"  Total:    {format_cents(total_value)}")
            print(f"  Cost:     {format_cents(args.cost)}")
            print(f"  Date:     {date_str}")

            if input("\nCommit? (y/N) ").lower() == "y":
                cur.execute(
                    """INSERT INTO "transaction"
                       (account, company, type, quantity, unit_value, total_value, cost, date)
                       VALUES (?, ?, 'sell', ?, ?, ?, ?, ?)""",
                    (account[0], company[0], args.quantity, args.price, total_value, args.cost, date_str)
                )
                conn.commit()
                print(f"{GREEN}Transaction recorded.{RESET}")

        # ----- DIVIDEND -----
        elif args.transaction_type == "dividend":
            account = get_or_prompt_account(cur, getattr(args, 'account', None))
            if not account:
                conn.close()
                return

            company = get_or_prompt_company(cur, args.name)
            if not company:
                conn.close()
                return

            date_str = args.date.strftime("%Y-%m-%d") if isinstance(args.date, datetime) else args.date

            print(f"\n{BOLD}Recording DIVIDEND transaction:{RESET}")
            print(f"  Account:  {account[1]}")
            print(f"  Company:  {company[2]}")
            print(f"  Amount:   {format_cents(args.amount)}")
            print(f"  Cost:     {format_cents(args.cost)}")
            print(f"  Date:     {date_str}")

            if input("\nCommit? (y/N) ").lower() == "y":
                cur.execute(
                    """INSERT INTO "transaction"
                       (account, company, type, total_value, cost, date)
                       VALUES (?, ?, 'dividend', ?, ?, ?)""",
                    (account[0], company[0], args.amount, args.cost, date_str)
                )
                conn.commit()
                print(f"{GREEN}Transaction recorded.{RESET}")

        # ----- INTEREST -----
        elif args.transaction_type == "interest":
            account = get_or_prompt_account(cur, getattr(args, 'account', None))
            if not account:
                conn.close()
                return

            date_str = args.date.strftime("%Y-%m-%d") if isinstance(args.date, datetime) else args.date

            print(f"\n{BOLD}Recording INTEREST transaction:{RESET}")
            print(f"  Account:  {account[1]}")
            print(f"  Amount:   {format_cents(args.amount)}")
            print(f"  Cost:     {format_cents(args.cost)}")
            print(f"  Date:     {date_str}")

            if input("\nCommit? (y/N) ").lower() == "y":
                cur.execute(
                    """INSERT INTO "transaction"
                       (account, type, total_value, cost, date)
                       VALUES (?, 'interest', ?, ?, ?)""",
                    (account[0], args.amount, args.cost, date_str)
                )
                conn.commit()
                print(f"{GREEN}Transaction recorded.{RESET}")

        # ----- DEPOSIT -----
        elif args.transaction_type == "deposit":
            account = get_or_prompt_account(cur, getattr(args, 'account', None))
            if not account:
                conn.close()
                return

            date_str = args.date.strftime("%Y-%m-%d") if isinstance(args.date, datetime) else args.date

            print(f"\n{BOLD}Recording DEPOSIT transaction:{RESET}")
            print(f"  Account:  {account[1]}")
            print(f"  Amount:   {format_cents(args.amount)}")
            print(f"  Cost:     {format_cents(args.cost)}")
            print(f"  Date:     {date_str}")

            if input("\nCommit? (y/N) ").lower() == "y":
                cur.execute(
                    """INSERT INTO "transaction"
                       (account, type, total_value, cost, date)
                       VALUES (?, 'deposit', ?, ?, ?)""",
                    (account[0], args.amount, args.cost, date_str)
                )
                conn.commit()
                print(f"{GREEN}Transaction recorded.{RESET}")

        # ----- WITHDRAWAL -----
        elif args.transaction_type == "withdrawal":
            account = get_or_prompt_account(cur, getattr(args, 'account', None))
            if not account:
                conn.close()
                return

            date_str = args.date.strftime("%Y-%m-%d") if isinstance(args.date, datetime) else args.date

            print(f"\n{BOLD}Recording WITHDRAWAL transaction:{RESET}")
            print(f"  Account:  {account[1]}")
            print(f"  Amount:   {format_cents(args.amount)}")
            print(f"  Cost:     {format_cents(args.cost)}")
            print(f"  Date:     {date_str}")

            if input("\nCommit? (y/N) ").lower() == "y":
                cur.execute(
                    """INSERT INTO "transaction"
                       (account, type, total_value, cost, date)
                       VALUES (?, 'withdrawal', ?, ?, ?)""",
                    (account[0], args.amount, args.cost, date_str)
                )
                conn.commit()
                print(f"{GREEN}Transaction recorded.{RESET}")

        # ----- TRANSFER -----
        elif args.transaction_type == "transfer":
            # Get source account
            cur.execute("SELECT id, name FROM account WHERE name LIKE ?", (f"%{args.from_account}%",))
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
            cur.execute("SELECT id, name FROM account WHERE name LIKE ?", (f"%{args.to_account}%",))
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

            date_str = args.date.strftime("%Y-%m-%d") if isinstance(args.date, datetime) else args.date

            print(f"\n{BOLD}Recording TRANSFER transaction:{RESET}")
            print(f"  From:     {from_account[1]}")
            print(f"  To:       {to_account[1]}")
            print(f"  Amount:   {format_cents(args.amount)}")
            print(f"  Cost:     {format_cents(args.cost)}")
            print(f"  Date:     {date_str}")

            if input("\nCommit? (y/N) ").lower() == "y":
                # Insert outgoing transfer (from source account)
                cur.execute(
                    """INSERT INTO "transaction"
                       (account, type, total_value, cost, date)
                       VALUES (?, 'transfer', ?, ?, ?)""",
                    (from_account[0], -args.amount, args.cost, date_str)
                )
                outgoing_id = cur.lastrowid

                # Insert incoming transfer (to destination account)
                cur.execute(
                    """INSERT INTO "transaction"
                       (account, type, total_value, cost, date, linked_transaction)
                       VALUES (?, 'transfer', ?, 0, ?, ?)""",
                    (to_account[0], args.amount, date_str, outgoing_id)
                )
                incoming_id = cur.lastrowid

                # Link the outgoing transaction to the incoming one
                cur.execute(
                    """UPDATE "transaction" SET linked_transaction = ? WHERE id = ?""",
                    (incoming_id, outgoing_id)
                )

                conn.commit()
                print(f"{GREEN}Transfer recorded (IDs: {outgoing_id} <-> {incoming_id}).{RESET}")

    conn.close()


if __name__ == "__main__":
    main()
