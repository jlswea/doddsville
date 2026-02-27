from datetime import datetime

from db import get_or_prompt_account, get_or_prompt_security
from formatting import BOLD, GREEN, RED, RESET, YELLOW, format_cents
from paperless import (
    get_or_create_dv_custom_field_id,
    insert_transaction_documents,
    resolve_doc_args,
    set_document_transaction_ids,
)


def handle_add(args, config, conn, cur):
    """Handle the 'add' command."""
    # ----- BUY -----
    if args.transaction_type == "buy":
        account = get_or_prompt_account(cur, getattr(args, "account", None))
        if not account:
            return

        security = get_or_prompt_security(cur, args.identifier)
        if not security:
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
        print(f"  Security: {security[2]}")
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
                   (account, security, type, quantity, unit_value, total_value, cost, date)
                   VALUES (?, ?, 'buy', ?, ?, ?, ?, ?)""",
                (
                    account[0],
                    security[0],
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
                try:
                    cf_id = get_or_create_dv_custom_field_id(config)
                    for did in doc_ids:
                        set_document_transaction_ids(
                            config, did, cf_id, [transaction_id]
                        )
                except Exception as e:
                    print(
                        f"  {YELLOW}Warning: Could not set transaction ID custom field: {e}{RESET}"
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
            return

        security = get_or_prompt_security(cur, args.name)
        if not security:
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
        print(f"  Security: {security[2]}")
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
                   (account, security, type, quantity, unit_value, total_value, cost, date)
                   VALUES (?, ?, 'sell', ?, ?, ?, ?, ?)""",
                (
                    account[0],
                    security[0],
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
                try:
                    cf_id = get_or_create_dv_custom_field_id(config)
                    for did in doc_ids:
                        set_document_transaction_ids(
                            config, did, cf_id, [transaction_id]
                        )
                except Exception as e:
                    print(
                        f"  {YELLOW}Warning: Could not set transaction ID custom field: {e}{RESET}"
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
            return

        security = get_or_prompt_security(cur, args.name)
        if not security:
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
        print(f"  Security: {security[2]}")
        print(f"  Amount:   {format_cents(args.amount)}")
        print(f"  Cost:     {format_cents(args.cost)}")
        print(f"  Date:     {date_str}")
        if doc_ids:
            print(f"  Docs:     {', '.join(str(d) for d in doc_ids)}")

        if input("\nCommit? (y/N) ").lower() == "y":
            cur.execute(
                """INSERT INTO "transaction"
                   (account, security, type, total_value, cost, date)
                   VALUES (?, ?, 'dividend', ?, ?, ?)""",
                (account[0], security[0], args.amount, args.cost, date_str),
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
                try:
                    cf_id = get_or_create_dv_custom_field_id(config)
                    for did in doc_ids:
                        set_document_transaction_ids(
                            config, did, cf_id, [transaction_id]
                        )
                except Exception as e:
                    print(
                        f"  {YELLOW}Warning: Could not set transaction ID custom field: {e}{RESET}"
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
                try:
                    cf_id = get_or_create_dv_custom_field_id(config)
                    for did in doc_ids:
                        set_document_transaction_ids(
                            config, did, cf_id, [transaction_id]
                        )
                except Exception as e:
                    print(
                        f"  {YELLOW}Warning: Could not set transaction ID custom field: {e}{RESET}"
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
                try:
                    cf_id = get_or_create_dv_custom_field_id(config)
                    for did in doc_ids:
                        set_document_transaction_ids(
                            config, did, cf_id, [transaction_id]
                        )
                except Exception as e:
                    print(
                        f"  {YELLOW}Warning: Could not set transaction ID custom field: {e}{RESET}"
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
                try:
                    cf_id = get_or_create_dv_custom_field_id(config)
                    for did in doc_ids:
                        set_document_transaction_ids(
                            config, did, cf_id, [transaction_id]
                        )
                except Exception as e:
                    print(
                        f"  {YELLOW}Warning: Could not set transaction ID custom field: {e}{RESET}"
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
            return
        if len(from_results) > 1:
            print(f"Multiple source accounts match '{args.from_account}':")
            for i, acc in enumerate(from_results):
                print(f"  {i + 1}: {acc[1]}")
            try:
                from_account = from_results[int(input("Select source: ")) - 1]
            except (ValueError, IndexError):
                print(f"{RED}Invalid selection.{RESET}")
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
            return
        if len(to_results) > 1:
            print(f"Multiple destination accounts match '{args.to_account}':")
            for i, acc in enumerate(to_results):
                print(f"  {i + 1}: {acc[1]}")
            try:
                to_account = to_results[int(input("Select destination: ")) - 1]
            except (ValueError, IndexError):
                print(f"{RED}Invalid selection.{RESET}")
                return
        else:
            to_account = to_results[0]

        if from_account[0] == to_account[0]:
            print(f"{RED}Source and destination accounts must be different.{RESET}")
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
                print(f"Linked {len(doc_ids)} document(s) to transaction {outgoing_id}")
                try:
                    cf_id = get_or_create_dv_custom_field_id(config)
                    for did in doc_ids:
                        set_document_transaction_ids(config, did, cf_id, [outgoing_id])
                except Exception as e:
                    print(
                        f"  {YELLOW}Warning: Could not set transaction ID custom field: {e}{RESET}"
                    )

            if failed_docs:
                print(
                    f"\n{YELLOW}Warning: {len(failed_docs)} document(s) could not be linked:{RESET}"
                )
                for f in failed_docs:
                    print(f"  - {f}")
                print("\nTo attach manually later, use:")
                print(f"  dv doc add {outgoing_id} <paperless_doc_id>")
