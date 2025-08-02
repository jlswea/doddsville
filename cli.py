import argparse
from datetime import datetime


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
    # This command is simple and has no sub-commands of its own.
    parser_list = main_commands.add_parser(
        "list", help="List all recorded transactions."
    )

    # --------------------------------------------------------------------------
    #                           COMMAND: "add"
    # --------------------------------------------------------------------------
    # Create the parser for the "add" command
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
    parser_buy.add_argument("ticker", type=str, help="Stock ticker symbol (e.g., AAPL)")
    parser_buy.add_argument("quantity", type=float, help="Number of shares bought")
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
        "ticker", type=str, help="Stock ticker symbol (e.g., GOOGL)"
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
    parser_div.add_argument("ticker", type=str, help="Stock ticker symbol (e.g., MSFT)")
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
        # The 'add' command was used, now check which transaction type
        if args.transaction_type == "buy":
            print("Recording a BUY transaction:")
            print(f"  Ticker:   {args.ticker.upper()}")
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
