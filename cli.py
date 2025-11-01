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

def main() -> None:
    parser = argparse.ArgumentParser(
        description="dv: Managing common stocks transactions"
    )

    main_commands = parser.add_subparsers(
        dest="command", required=True, help="Available commands"
    )

    # --------------------------------------------------------------------------
    #                           COMMAND: "list"
    # --------------------------------------------------------------------------

    parser_list = main_commands.add_parser(
        "list", help="List all recorded transactions."
    )

    # --------------------------------------------------------------------------
    #                           COMMAND: "add"
    # --------------------------------------------------------------------------

    parser_add = main_commands.add_parser(
        "add", help="Add a new transaction (buy, sell, or dividend)."
    )

    add_transaction_types = parser_add.add_subparsers(
        dest="transaction_type", required=True, help="Type of transaction to add"
    )

    # --- "add buy" sub-command ---
    parser_buy = add_transaction_types.add_parser(
        "buy", help="Record a stock purchase."
    )
    parser_buy.add_argument("name", type=str, help="Stock name")
    parser_buy.add_argument("quantity", type=int, help="Number of shares bought")
    parser_buy.add_argument("price", type=float, help="Price per share")
    parser_buy.add_argument(
        "--date",
        default=datetime.now().strftime("%Y-%m-%d"),
        help="Transaction date (YYYY-MM-DD)",
    )
    parser_buy.add_argument(
        "--fees", type=float, default=0.0, help="Any commission or fees paid"
    )
    parser_buy.add_argument(
        "--transaction",
        "-t",
        type=str,
        help="A buy transaction of format: {DATETIME} {SYMBOL} {NUMBER_OF_SHARES} {PRICE_PER_SHARE}",
    )

    # --- "add sell" sub-command ---
    parser_sell = add_transaction_types.add_parser("sell", help="Record a stock sale.")
    parser_sell.add_argument(
        "name", type=str, help="Stock name; Has to be unique in portfolio table"
    )
    parser_sell.add_argument("quantity", type=float, help="Number of shares sold")
    parser_sell.add_argument("price", type=float, help="Price per share")
    parser_sell.add_argument(
        "--date",
        default=datetime.now().strftime("%Y-%m-%d"),
        help="Transaction date (YYYY-MM-DD)",
    )
    parser_sell.add_argument(
        "--fees", type=float, default=0.0, help="Any commission or fees paid"
    )
    parser_sell.add_argument(
        "--transaction",
        "-t",
        type=str,
        help="A sell transaction of format: {DATETIME} {SYMBOL} {NUMBER_OF_SHARES} {PRICE_PER_SHARE}",
    )

    # --- "add div" (dividend) sub-command ---
    parser_div = add_transaction_types.add_parser(
        "div", help="Record a dividend payment."
    )
    parser_div.add_argument(
        "name", type=str, help="Stock name, has to have a unique match in the database"
    )
    parser_div.add_argument("amount", type=float, help="Total dividend amount received")
    parser_div.add_argument(
        "--date",
        default=datetime.now().strftime("%Y-%m-%d"),
        help="Payment date (YYYY-MM-DD)",
    )
    parser_div.add_argument(
        "--tax", type=float, default=0.0, help="Any tax withheld from the dividend"
    )

    parser_div.add_argument(
        "--transaction",
        "-t",
        type=str,
        help="A dividend transaction of format: {DATETIME} {SYMBOL} {AMOUNT_IN_EURO}",
    )

    # --- "--version, -v" ---
    parser.add_argument(
        "-v",
        "--version",
        action="version",
        version="doddsville@0.0.1",
        help="The installed version of the doddsville CLI",
    )

    args = parser.parse_args()

    if args.command == "list":
        print("Listing all transactions...")

    elif args.command == "add":
        # The add command was invoked, we will need a DB connection
        conn = sqlite3.connect("data.db")
        cur = conn.cursor()

        if args.transaction_type == "buy":
            
            cur.execute("select * from com where name like ?", (f"%{args.name}%",))
            res = cur.fetchall()
            selected_company = res[0]
            if len(res) > 1:
                print(f"There are multiple options for name {args.name}:")
                for i, com in enumerate(res):
                    print(f"{BOLD}{GREEN}{i+1}{RESET}:: Name: {com[2]}, Isin: {com[1]}, ID: {com[0]}")

                # Let the user select the correct option
                option_input = input("Which option should be added?")
                try:
                    option = int(option_input)
                    selected_company = res[option- 1]
                except ValueError:
                    print("Invalid input: Please enter a number.")
                except IndexError:
                    print(f"Invalid option: Please select a number between 1 and {len(res)}.")


            print("Recording a BUY transaction:")
            print(f"  Name:     {selected_company[2]}")
            print(f"  Quantity: {args.quantity}")
            print(f"  Price:    ${args.price:.2f}")
            print(f"  Date:     {args.date}")
            print(f"  Fees:     ${args.fees:.2f}")


        elif args.transaction_type == "sell":
            print("Recording a SELL transaction:")
            print(f"  Ticker:   {args.ticker.upper()}")
            print(f"  Quantity: {args.quantity}")
            print(f"  Price:    ${args.price:.2f}")
            print(f"  Date:     {args.date}")
            print(f"  Fees:     ${args.fees:.2f}")

        elif args.transaction_type == "div":
            print("Recording a DIVIDEND transaction:")
            print(f"  Ticker:   {args.ticker.upper()}")
            print(f"  Amount:   ${args.amount:.2f}")
            print(f"  Date:     {args.date}")
            print(f"  Tax:      ${args.tax:.2f}")


if __name__ == "__main__":
    main()
