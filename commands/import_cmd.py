import json
from pathlib import Path

from db import get_current_holdings, get_or_prompt_account, get_or_prompt_security
from formatting import BOLD, GREEN, RED, RESET, YELLOW
from paperless import (
    DocumentMetadata,
    fetch_paperless_correspondents,
    fetch_paperless_document_types,
    fetch_paperless_storage_paths,
    fetch_paperless_tags,
    get_or_create_dv_custom_field_id,
    insert_transaction_documents,
    resolve_correspondent,
    resolve_document_type,
    resolve_storage_path,
    resolve_tags,
    set_document_transaction_ids,
    transaction_to_dict,
    upload_document_to_paperless,
)
from parsers import extract_pdf_content, list_parsers, parse_document
from ui import (
    edit_document_metadata,
    edit_transactions_interactive,
    preview_document_metadata,
    preview_import_transactions,
)


def handle_import(args, config, conn, cur):
    """Handle the 'import' command."""
    # Handle --list-parsers
    if args.list_parsers:
        print(f"\n{BOLD}Available parsers:{RESET}\n")
        for p in list_parsers():
            print(f"  {GREEN}{p['name']}{RESET}")
            if p["correspondent"]:
                print(f"    Correspondent: {p['correspondent']}")
            if p["document_type"]:
                print(f"    Document type: {p['document_type']}")
            if p["tags"]:
                print(f"    Tags: {', '.join(p['tags'])}")
            print()
        return

    pdf_path = args.pdf_file

    # pdf_file is required unless --list-parsers was used
    if not pdf_path:
        print(f"{RED}Error: pdf_file is required{RESET}")
        print("Usage: dv import <pdf_file> [options]")
        return

    # Override model if specified
    if args.model:
        config["ollama_model"] = args.model

    # Step 1: Validate PDF exists
    if not Path(pdf_path).exists():
        print(f"{RED}PDF file not found: {pdf_path}{RESET}")
        return

    # Step 2: Extract PDF content
    print(f"Extracting content from {Path(pdf_path).name}...")
    try:
        pdf_content = extract_pdf_content(pdf_path)
    except ValueError as e:
        print(f"{RED}{e}{RESET}")
        print("For scanned documents, consider using OCR tools first.")
        return
    except Exception as e:
        print(f"{RED}Failed to read PDF: {e}{RESET}")
        return

    # Step 3: If --raw, show text and exit
    if args.raw:
        print(f"\n{BOLD}Extracted text ({len(pdf_content.text)} chars):{RESET}\n")
        print(pdf_content.text)
        return

    # Step 4: Parse with parser module
    force_parser = getattr(args, "parser", None)
    if force_parser:
        print(f"Parsing with {force_parser} parser...")
    else:
        print("Auto-detecting parser and parsing document...")

    # Pass PDF path for template-based parsers that need coordinate extraction
    config["_pdf_path"] = pdf_path

    try:
        parse_result = parse_document(pdf_content, config, force_parser=force_parser)
    except ValueError as e:
        print(f"{RED}{e}{RESET}")
        return
    except ConnectionError as e:
        print(f"{RED}{e}{RESET}")
        return
    except RuntimeError as e:
        print(f"{RED}{e}{RESET}")
        return
    except json.JSONDecodeError as e:
        print(f"{RED}Invalid JSON from parser: {e}{RESET}")
        print(
            "The parser may have produced malformed output. Try again or use a different parser."
        )
        return

    if not parse_result or not parse_result.transactions:
        print(f"{YELLOW}No transactions found in document.{RESET}")
        print("Try running with --raw to see extracted text.")
        return

    print(
        f"  {GREEN}✓{RESET} Parsed with {parse_result.parser_name} parser ({parse_result.confidence.value} confidence)"
    )

    # Convert transactions to dict format for compatibility with existing preview/edit functions
    valid_transactions = [transaction_to_dict(txn) for txn in parse_result.transactions]

    if not valid_transactions:
        print(f"{RED}No valid transactions after parsing.{RESET}")
        return

    # Step 6: Resolve account
    account = get_or_prompt_account(cur, getattr(args, "account", None))
    if not account:
        return

    # Step 7: Resolve securities for transactions
    for txn in valid_transactions:
        if txn.get("security"):
            sec = get_or_prompt_security(cur, txn["security"])
            if sec:
                txn["_security_id"] = sec[0]
                txn["_security_name"] = sec[2]
            else:
                # Company not found - mark for skipping or ask user
                print(
                    f"{YELLOW}Skipping transaction (security not found): {txn.get('security')}{RESET}"
                )
                txn["_skip"] = True

    # Filter out skipped transactions
    valid_transactions = [t for t in valid_transactions if not t.get("_skip")]

    if not valid_transactions:
        print(f"{RED}No valid transactions remaining after security resolution.{RESET}")
        return

    # Step 7b: Fetch current holdings for sanity checks
    for txn in valid_transactions:
        if txn.get("_security_id"):
            txn["_current_holdings"] = get_current_holdings(
                cur, txn["_security_id"], account[0]
            )

    # Step 8: Preview
    preview_import_transactions(valid_transactions, account[1])

    # Step 8b: Edit transactions (optional)
    if input("\nEdit transactions? (y/N) ").lower() == "y":
        valid_transactions = edit_transactions_interactive(valid_transactions, cur)
        if not valid_transactions:
            print(f"{RED}No transactions remaining after editing.{RESET}")
            return
        # Re-resolve securities for any edited transactions
        for txn in valid_transactions:
            if txn.get("security") and not txn.get("_security_id"):
                sec = get_or_prompt_security(cur, txn["security"])
                if sec:
                    txn["_security_id"] = sec[0]
                    txn["_security_name"] = sec[2]
                else:
                    print(
                        f"{YELLOW}Skipping transaction (security not found): {txn.get('security')}{RESET}"
                    )
                    txn["_skip"] = True
        valid_transactions = [t for t in valid_transactions if not t.get("_skip")]
        if not valid_transactions:
            print(
                f"{RED}No valid transactions remaining after security resolution.{RESET}"
            )
            return
        # Refresh holdings for sanity checks
        for txn in valid_transactions:
            if txn.get("_security_id"):
                txn["_current_holdings"] = get_current_holdings(
                    cur, txn["_security_id"], account[0]
                )
        # Show updated preview
        preview_import_transactions(valid_transactions, account[1])

    # Step 9: If --dry-run, exit
    if args.dry_run:
        print(f"\n{YELLOW}Dry run - no transactions inserted.{RESET}")
        return

    # Step 10: Confirm
    if input("\nImport these transactions? (y/N) ").lower() != "y":
        print("Import cancelled.")
        return

    # Step 11: Insert transactions
    transaction_ids = []
    for txn in valid_transactions:
        txn_type = txn["type"]
        date_str = txn["date"]
        cost = txn.get("cost_cents", 0)
        security_id = txn.get("_security_id")
        quantity = txn.get("quantity", 1)
        unit_price = txn.get("unit_price_cents", 0)
        currency = txn.get("currency", "EUR")
        exchange_rate = txn.get("exchange_rate", 1.0)
        # Compute total from unit * quantity
        total_value = unit_price * quantity

        if txn_type in {"buy", "sell"}:
            cur.execute(
                """INSERT INTO "transaction"
                   (account, security, type, quantity, unit_value, total_value, cost, date, currency, exchange_rate)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    account[0],
                    security_id,
                    txn_type,
                    quantity,
                    unit_price,
                    total_value,
                    cost,
                    date_str,
                    currency,
                    exchange_rate,
                ),
            )
        elif txn_type == "dividend":
            cur.execute(
                """INSERT INTO "transaction"
                   (account, security, type, quantity, unit_value, total_value, cost, date, currency, exchange_rate)
                   VALUES (?, ?, 'dividend', ?, ?, ?, ?, ?, ?, ?)""",
                (
                    account[0],
                    security_id,
                    quantity,
                    unit_price,
                    total_value,
                    cost,
                    date_str,
                    currency,
                    exchange_rate,
                ),
            )
        else:
            # interest, deposit, withdrawal (quantity=1, unit_value=amount)
            cur.execute(
                """INSERT INTO "transaction"
                   (account, type, quantity, unit_value, total_value, cost, date, currency, exchange_rate)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    account[0],
                    txn_type,
                    quantity,
                    unit_price,
                    total_value,
                    cost,
                    date_str,
                    currency,
                    exchange_rate,
                ),
            )
        transaction_ids.append(cur.lastrowid)

    conn.commit()
    print(f"\n{GREEN}Imported {len(transaction_ids)} transaction(s).{RESET}")

    # Step 12: Upload PDF to Paperless (unless --no-upload)
    if not args.no_upload:
        paperless_url = config.get("paperless_url")
        paperless_token = config.get("paperless_token")

        if paperless_url and paperless_token:
            # Fetch Paperless options for metadata editing
            try:
                print("\nFetching Paperless metadata options...")
                correspondents = fetch_paperless_correspondents(config)
                doc_types = fetch_paperless_document_types(config)
                storage_paths = fetch_paperless_storage_paths(config)
                tags = fetch_paperless_tags(config)

                # Find 'dv' tag (required) and workflow tags to remove after upload
                dv_tag_id = None
                remove_tag_ids = []
                for tag in tags:
                    if tag["name"] == "dv":
                        dv_tag_id = tag["id"]
                    elif tag["name"] in ("todo", "inbox"):
                        remove_tag_ids.append(tag["id"])

                # Check required items
                if dv_tag_id is None:
                    print(
                        f"\n{RED}✗ Cannot upload: tag 'dv' not found in paperless-ngx.{RESET}"
                    )
                    print(
                        "  Please create the 'dv' tag in paperless before uploading documents."
                    )
                    print(
                        f"  You can manually upload later with: dv doc add <transaction_id> {pdf_path}"
                    )
                else:
                    # Initialize metadata from parser result, using PDF filename as title
                    parser_metadata = parse_result.metadata
                    metadata = DocumentMetadata(
                        title=Path(pdf_path).stem,
                        created=parser_metadata.created,
                    )

                    # Resolve names to IDs from parser metadata
                    metadata.correspondent_id = resolve_correspondent(
                        parser_metadata.correspondent, correspondents
                    )
                    metadata.document_type_id = resolve_document_type(
                        parser_metadata.document_type, doc_types
                    )
                    metadata.storage_path_id = resolve_storage_path(
                        parser_metadata.storage_path, storage_paths
                    )
                    metadata.tag_ids = resolve_tags(parser_metadata.tags, tags)

                    # Always add 'dv' tag
                    if dv_tag_id not in metadata.tag_ids:
                        metadata.tag_ids.append(dv_tag_id)

                    # Warn if correspondent not resolved
                    if (
                        parser_metadata.correspondent
                        and metadata.correspondent_id is None
                    ):
                        print(
                            f"\n{YELLOW}⚠ No correspondent matching '{parser_metadata.correspondent}' found.{RESET}"
                        )
                        print(
                            "  Please set the correspondent manually in the metadata editor."
                        )
                    elif metadata.correspondent_id is None:
                        print(
                            f"\n{YELLOW}⚠ No correspondent in document metadata.{RESET}"
                        )
                        print(
                            "  Please set the correspondent manually in the metadata editor."
                        )

                    # Preview and optionally edit metadata
                    preview_document_metadata(
                        metadata, correspondents, doc_types, storage_paths, tags
                    )

                    if input("\nEdit metadata before upload? (y/N) ").lower() == "y":
                        metadata = edit_document_metadata(
                            metadata, correspondents, doc_types, storage_paths, tags
                        )

                    print(f"\nUploading {Path(pdf_path).name} to paperless-ngx...")
                    try:
                        doc_id = upload_document_to_paperless(
                            pdf_path, config, dv_tag_id, metadata, remove_tag_ids
                        )
                        print(f"  {GREEN}✓{RESET} Uploaded as document {doc_id}")

                        # Link document to all transactions
                        for tid in transaction_ids:
                            insert_transaction_documents(cur, tid, [doc_id])
                        conn.commit()
                        print(
                            f"  Linked document to {len(transaction_ids)} transaction(s)"
                        )

                        # Set custom field on Paperless document
                        try:
                            cf_id = get_or_create_dv_custom_field_id(config)
                            set_document_transaction_ids(
                                config, doc_id, cf_id, transaction_ids
                            )
                        except Exception as e:
                            print(
                                f"  {YELLOW}Warning: Could not set transaction ID custom field: {e}{RESET}"
                            )
                    except Exception as e:
                        print(
                            f"  {YELLOW}Warning: Could not upload to paperless: {e}{RESET}"
                        )
                        print(
                            f"  You can manually link later with: dv doc add <transaction_id> {pdf_path}"
                        )

            except Exception as e:
                print(
                    f"  {YELLOW}Warning: Could not fetch Paperless metadata options: {e}{RESET}"
                )
                print(
                    f"  You can manually upload later with: dv doc add <transaction_id> {pdf_path}"
                )
        else:
            print(
                f"\n{YELLOW}Paperless not configured - skipping document upload.{RESET}"
            )
            print("Configure with: export DV_PAPERLESS_URL=<url>")
