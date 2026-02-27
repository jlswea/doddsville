from formatting import BOLD, RESET, format_cents


def handle_list(args, config, cur):
    """Handle the 'list' command."""
    query = """
        SELECT
            t.id,
            a.name as account,
            t.type,
            s.name as security,
            t.quantity,
            t.unit_value,
            t.total_value,
            t.cost,
            t.date,
            t.linked_transaction,
            (SELECT GROUP_CONCAT(paperless_id) FROM transaction_document WHERE transaction_id = t.id) as doc_ids,
            t.currency,
            t.exchange_rate
        FROM "transaction" t
        JOIN account a ON t.account = a.id
        LEFT JOIN security s ON t.security = s.id
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

        # Check if any transaction has non-EUR currency (currency is at index 11)
        has_fx = any(t[11] and t[11] != "EUR" for t in transactions)

        if has_fx:
            print(
                f"{BOLD}{'ID':<5} {'Date':<12} {'Account':<15} {'Type':<10} {'Security':<20} {'Qty':<6} {'Unit':<10} {'Total':<12} {'Ccy':<4} {'EUR':<10} {'Cost':<8} {'Docs'}{RESET}"
            )
            print("-" * 130)
        else:
            print(
                f"{BOLD}{'ID':<5} {'Date':<12} {'Account':<15} {'Type':<10} {'Security':<20} {'Qty':<6} {'Unit':<10} {'Total':<12} {'Cost':<8} {'Docs'}{RESET}"
            )
            print("-" * 115)

        for t in transactions:
            (
                tid,
                account,
                ttype,
                security,
                qty,
                unit,
                total,
                cost,
                date,
                linked,
                doc_ids,
                currency,
                exchange_rate,
            ) = t
            security_str = str(security).split(" ")[0] or "-"
            qty_str = str(qty) if qty else "-"
            unit_str = format_cents(unit) if unit else "-"
            total_str = format_cents(total) if total else "-"
            cost_str = format_cents(cost) if cost else "-"
            currency = currency or "EUR"
            exchange_rate = exchange_rate or 1.0

            # Format document links
            if doc_ids and paperless_url:
                doc_urls = ", ".join(
                    f"{paperless_url}/documents/{d}" for d in doc_ids.split(",")
                )
            elif doc_ids:
                doc_urls = doc_ids  # Just show IDs if no URL configured
            else:
                doc_urls = "-"

            if has_fx:
                # Calculate EUR value
                eur_str = "-"
                if total and exchange_rate:
                    eur_value = int(total * exchange_rate)
                    eur_str = format_cents(eur_value)
                print(
                    f"{tid:<5} {date:<12} {account:<15} {ttype:<10} {security_str:<20} {qty_str:<6} {unit_str:<10} {total_str:<12} {currency:<4} {eur_str:<10} {cost_str:<8} {doc_urls}"
                )
            else:
                print(
                    f"{tid:<5} {date:<12} {account:<15} {ttype:<10} {security_str:<20} {qty_str:<6} {unit_str:<10} {total_str:<12} {cost_str:<8} {doc_urls}"
                )
