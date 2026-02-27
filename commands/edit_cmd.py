import requests

from db import get_or_prompt_security
from formatting import GREEN, RED, RESET, YELLOW
from paperless import get_paperless_headers
from ui import edit_single_transaction


def handle_edit(args, config, conn, cur):
    """Handle the 'edit' command — edit an existing transaction."""
    txn_id = args.transaction_id

    cur.execute(
        """
        SELECT t.id, t.account, t.security, t.type, t.total_value, t.unit_value,
               t.quantity, t.cost, t.date, t.linked_transaction, t.currency, t.exchange_rate,
               s.name AS security_name, s.id AS security_id,
               a.name AS account_name
        FROM "transaction" t
        LEFT JOIN security s ON t.security = s.id
        LEFT JOIN account a ON t.account = a.id
        WHERE t.id = ?
        """,
        (txn_id,),
    )
    row = cur.fetchone()
    if not row:
        print(f"{RED}Transaction {txn_id} not found.{RESET}")
        return

    (
        _id, account_id, _security_fk, txn_type, total_value, unit_value,
        quantity, cost, date, linked_transaction, currency, exchange_rate,
        security_name, security_id, account_name,
    ) = row

    # Build dict compatible with edit_single_transaction
    txn_dict = {
        "type": txn_type,
        "date": date,
        "security": security_name or "",
        "quantity": quantity or 1,
        "unit_price_cents": unit_value or 0,
        "cost_cents": cost or 0,
        "confidence": "high",
        "currency": currency or "EUR",
        "exchange_rate": exchange_rate or 1.0,
        "_security_id": security_id,
        "_security_name": security_name,
    }

    print(f"Editing transaction {txn_id} (account: {account_name})")
    result = edit_single_transaction(txn_dict)

    if result is None:
        # Delete
        if linked_transaction:
            cur.execute('DELETE FROM "transaction" WHERE id = ?', (linked_transaction,))
            print(f"  Deleted linked transfer leg (ID {linked_transaction})")
        cur.execute('DELETE FROM "transaction" WHERE id = ?', (txn_id,))
        conn.commit()
        print(f"{GREEN}Transaction {txn_id} deleted.{RESET}")
        return

    # Resolve security if changed or type changed
    new_type = result["type"]
    stock_types = ("buy", "sell", "dividend")
    new_security_id = security_id

    if new_type in stock_types:
        new_security_name = result.get("security", "")
        if new_security_name and new_security_name != security_name:
            resolved = get_or_prompt_security(cur, new_security_name)
            if resolved:
                new_security_id = resolved[0]
            else:
                print(f"{YELLOW}Security not found, keeping previous.{RESET}")
    else:
        new_security_id = None

    new_unit = result.get("unit_price_cents", 0) or 0
    new_qty = result.get("quantity", 1) or 1
    new_total = new_unit * new_qty
    new_cost = result.get("cost_cents", 0) or 0
    new_currency = result.get("currency", "EUR")
    new_exchange_rate = result.get("exchange_rate", 1.0)

    cur.execute(
        """
        UPDATE "transaction"
        SET type = ?, security = ?, total_value = ?, unit_value = ?,
            quantity = ?, cost = ?, date = ?, currency = ?, exchange_rate = ?
        WHERE id = ?
        """,
        (
            new_type, new_security_id, new_total, new_unit,
            new_qty, new_cost, result.get("date", date),
            new_currency, new_exchange_rate, txn_id,
        ),
    )

    # For transfers, update the linked leg
    if linked_transaction:
        cur.execute(
            """
            UPDATE "transaction"
            SET total_value = ?, date = ?
            WHERE id = ?
            """,
            (-new_total, result.get("date", date), linked_transaction),
        )

    conn.commit()
    print(f"{GREEN}Transaction {txn_id} updated.{RESET}")
