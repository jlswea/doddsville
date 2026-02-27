from formatting import BOLD, RESET, YELLOW, format_cents, format_cents_colored


def handle_report(args, cur):
    """Handle the 'report' command."""
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
                s.name as security,
                SUM(CASE WHEN t.type = 'buy' THEN t.quantity ELSE 0 END) as bought,
                SUM(CASE WHEN t.type = 'sell' THEN t.quantity ELSE 0 END) as sold,
                SUM(CASE WHEN t.type = 'buy' THEN t.total_value ELSE 0 END) as total_cost,
                SUM(CASE WHEN t.type = 'sell' THEN t.total_value ELSE 0 END) as total_proceeds
            FROM "transaction" t
            JOIN account a ON t.account = a.id
            JOIN security s ON t.security = s.id
            WHERE t.type IN ('buy', 'sell') AND {date_filter} AND {account_filter}
            GROUP BY a.id, s.id
            HAVING (bought - sold) > 0
            ORDER BY a.name, s.name
        """
        cur.execute(query, date_params + account_params)
        results = cur.fetchall()

        if not results:
            print("\nNo holdings found.")
        else:
            print(f"\n{BOLD}Portfolio Holdings:{RESET}")
            print(
                f"{'Account':<20} {'Security':<25} {'Shares':>8} {'Avg Cost':>12} {'Total Cost':>14}"
            )
            print("-" * 85)

            current_account = None
            for (
                account,
                security,
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
                        f"{account:<20} {security:<25} {shares:>8} {format_cents(avg_cost):>12} {format_cents(remaining_cost):>14}"
                    )

    # ----- PERFORMANCE REPORT -----
    elif args.report_type == "performance":
        # Get realized gains/losses per security
        query = f"""
            SELECT
                s.name as security,
                SUM(CASE WHEN t.type = 'buy' THEN t.quantity ELSE 0 END) as total_bought,
                SUM(CASE WHEN t.type = 'sell' THEN t.quantity ELSE 0 END) as total_sold,
                SUM(CASE WHEN t.type = 'buy' THEN t.total_value ELSE 0 END) as buy_value,
                SUM(CASE WHEN t.type = 'sell' THEN t.total_value ELSE 0 END) as sell_value,
                SUM(CASE WHEN t.type = 'dividend' THEN t.total_value ELSE 0 END) as dividends,
                SUM(COALESCE(t.cost, 0)) as fees
            FROM "transaction" t
            JOIN account a ON t.account = a.id
            JOIN security s ON t.security = s.id
            WHERE t.type IN ('buy', 'sell', 'dividend') AND {date_filter} AND {account_filter}
            GROUP BY s.id
            ORDER BY s.name
        """
        cur.execute(query, date_params + account_params)
        results = cur.fetchall()

        if not results:
            print("\nNo investment transactions found.")
        else:
            print(f"\n{BOLD}Investment Performance:{RESET}")
            print(
                f"{'Security':<25} {'Bought':>8} {'Sold':>8} {'Buy Value':>12} {'Sell Value':>12} {'Realized G/L':>14} {'Dividends':>12}"
            )
            print("-" * 105)

            total_realized = 0
            total_dividends = 0
            total_fees = 0

            for (
                security,
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
                    f"{security:<25} {bought:>8} {sold:>8} {format_cents(buy_value):>12} {format_cents(sell_value):>12} {realized_str:>23} {format_cents(dividends):>12}"
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
                s.id,
                SUM(CASE WHEN t.type = 'buy' THEN t.quantity ELSE 0 END) as bought,
                SUM(CASE WHEN t.type = 'sell' THEN t.quantity ELSE 0 END) as sold,
                SUM(CASE WHEN t.type = 'buy' THEN t.total_value ELSE 0 END) as buy_value,
                SUM(CASE WHEN t.type = 'sell' THEN t.total_value ELSE 0 END) as sell_value
            FROM "transaction" t
            JOIN account a ON t.account = a.id
            JOIN security s ON t.security = s.id
            WHERE t.type IN ('buy', 'sell') AND {date_filter} AND {account_filter}
            GROUP BY s.id
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
