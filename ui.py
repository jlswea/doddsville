from formatting import BLUE, BOLD, GREEN, RED, RESET, YELLOW, format_cents
from paperless import DocumentMetadata


def _get_name_by_id(items: list[dict], item_id: int | None) -> str:
    """Get name from a list of {id, name} dicts by ID."""
    if item_id is None:
        return "(none)"
    for item in items:
        if item["id"] == item_id:
            return item["name"]
    return f"(unknown: {item_id})"


def _get_tag_names(tags: list[dict], tag_ids: list[int]) -> str:
    """Get comma-separated tag names from tag IDs."""
    if not tag_ids:
        return "(none)"
    names = []
    for tid in tag_ids:
        for tag in tags:
            if tag["id"] == tid:
                names.append(tag["name"])
                break
    return ", ".join(names) if names else "(none)"


def preview_document_metadata(
    metadata: DocumentMetadata,
    correspondents: list[dict],
    doc_types: list[dict],
    storage_paths: list[dict],
    tags: list[dict],
) -> None:
    """Display a formatted preview of document metadata."""
    print(f"\n{BOLD}Document Metadata Preview:{RESET}\n")
    print(f"  1. Title:         {metadata.title or '(empty)'}")
    print(f"  2. Date:          {metadata.created or '(empty)'}")
    print(
        f"  3. Correspondent: {_get_name_by_id(correspondents, metadata.correspondent_id)}"
    )
    print(
        f"  4. Type:          {_get_name_by_id(doc_types, metadata.document_type_id)}"
    )
    print(
        f"  5. Storage Path:  {_get_name_by_id(storage_paths, metadata.storage_path_id)}"
    )
    print(f"  6. Tags:          {_get_tag_names(tags, metadata.tag_ids)}")
    print(f"  7. ASN:           {metadata.archive_serial_number or '(empty)'}")


def _select_from_list(
    items: list[dict], prompt_text: str, allow_none: bool = True
) -> int | None:
    """Interactive selection from a list of {id, name} dicts."""
    print(f"\n{prompt_text}")
    if allow_none:
        print(f"  {BLUE}0{RESET}. (none)")
    for i, item in enumerate(items, 1):
        print(f"  {BLUE}{i}{RESET}. {item['name']}")

    while True:
        try:
            choice = input(f"Choice [{0 if allow_none else 1}]: ").strip()
            if not choice:
                return None if allow_none else (items[0]["id"] if items else None)

            idx = int(choice)
            if allow_none and idx == 0:
                return None
            if 1 <= idx <= len(items):
                return items[idx - 1]["id"]
            print(f"  {RED}Invalid choice. Enter 0-{len(items)}{RESET}")
        except ValueError:
            print(f"  {RED}Please enter a number{RESET}")


def _select_tags(tags: list[dict], current_ids: list[int]) -> list[int]:
    """Interactive multi-select for tags."""
    print("\nSelect tags (enter numbers separated by comma, or empty for none):")
    for i, tag in enumerate(tags, 1):
        marker = "*" if tag["id"] in current_ids else " "
        print(f"  {BLUE}{i}{RESET}. [{marker}] {tag['name']}")

    while True:
        current_display = ", ".join(
            str(i + 1) for i, t in enumerate(tags) if t["id"] in current_ids
        )
        choice = input(f"Tags [{current_display or 'none'}]: ").strip()

        if not choice:
            return current_ids  # Keep current selection

        try:
            if choice.lower() == "none" or choice == "0":
                return []

            indices = [int(x.strip()) for x in choice.split(",")]
            selected_ids = []
            for idx in indices:
                if 1 <= idx <= len(tags):
                    selected_ids.append(tags[idx - 1]["id"])
                else:
                    print(f"  {RED}Invalid index: {idx}{RESET}")
                    continue
            return selected_ids
        except ValueError:
            print(f"  {RED}Please enter numbers separated by comma{RESET}")


def edit_document_metadata(
    metadata: DocumentMetadata,
    correspondents: list[dict],
    doc_types: list[dict],
    storage_paths: list[dict],
    tags: list[dict],
) -> DocumentMetadata:
    """Interactive editor for document metadata."""
    while True:
        preview_document_metadata(
            metadata, correspondents, doc_types, storage_paths, tags
        )
        print()
        choice = input("Enter number to edit (or Enter to confirm): ").strip()

        if not choice:
            return metadata

        try:
            field_num = int(choice)
        except ValueError:
            print(f"{RED}Please enter a number{RESET}")
            continue

        if field_num == 1:  # Title
            new_title = input(f"Title [{metadata.title}]: ").strip()
            if new_title:
                metadata.title = new_title
        elif field_num == 2:  # Date
            new_date = input(f"Date (YYYY-MM-DD) [{metadata.created}]: ").strip()
            if new_date:
                metadata.created = new_date
        elif field_num == 3:  # Correspondent
            metadata.correspondent_id = _select_from_list(
                correspondents, "Select correspondent:"
            )
        elif field_num == 4:  # Document Type
            metadata.document_type_id = _select_from_list(
                doc_types, "Select document type:"
            )
        elif field_num == 5:  # Storage Path
            metadata.storage_path_id = _select_from_list(
                storage_paths, "Select storage path:"
            )
        elif field_num == 6:  # Tags
            metadata.tag_ids = _select_tags(tags, metadata.tag_ids)
        elif field_num == 7:  # ASN
            new_asn = input(f"ASN [{metadata.archive_serial_number}]: ").strip()
            if new_asn:
                metadata.archive_serial_number = new_asn
        else:
            print(f"{RED}Invalid choice. Enter 1-7{RESET}")


def _preview_single_transaction(txn: dict, idx: int) -> None:
    """Display a single transaction for editing."""
    txn_type = txn.get("type", "?")
    currency = txn.get("currency", "EUR")
    exchange_rate = txn.get("exchange_rate", 1.0)
    quantity = txn.get("quantity", 1)
    unit_price = txn.get("unit_price_cents", 0)
    # Compute totals
    total_orig = unit_price * quantity if unit_price and quantity else 0
    total_eur = int(total_orig * exchange_rate)
    cost = txn.get("cost_cents", 0)
    net_eur = total_eur - cost

    print(f"\n{BOLD}Editing transaction #{idx}:{RESET}")
    print(f"  1. Type:         {txn_type}")
    print(f"  2. Date:         {txn.get('date', '?')}")
    print(f"  3. Security:     {txn.get('security', '-')}")
    print(f"  4. Quantity:     {quantity}")
    print(
        f"  5. Unit price:   {format_cents(unit_price, currency) if unit_price else '-'}"
    )
    print(f"  6. Fees (EUR):   {format_cents(cost) if cost else '-'}")
    print(f"  7. Confidence:   {txn.get('confidence', '-')}")
    print(f"  8. Currency:     {currency}")
    print(
        f"  9. Exchange rate: {exchange_rate:.6f}"
        if exchange_rate != 1.0
        else f"  9. Exchange rate: 1.0 (no conversion)"
    )
    print(f"  ---")
    print(
        f"  {BOLD}Computed:{RESET}  Total: {format_cents(total_orig, currency)}  EUR: {format_cents(total_eur)}  Net: {format_cents(net_eur)}"
    )
    print(f" 10. {RED}Delete this transaction{RESET}")


def _input_cents(prompt: str, current: int | None, currency: str = "EUR") -> int | None:
    """Input a monetary value and convert to cents."""
    current_display = format_cents(current, currency) if current else "-"
    value = input(f"{prompt} [{current_display}]: ").strip()
    if not value:
        return current
    try:
        # Parse as decimal and convert to cents
        if "." not in value:
            value = value + ".00"
        parts = value.replace(",", ".").split(".")
        euros = int(parts[0])
        cents = int(parts[1][:2].ljust(2, "0"))
        return euros * 100 + cents
    except (ValueError, IndexError):
        print(f"  {RED}Invalid amount{RESET}")
        return current


def edit_single_transaction(txn: dict, cur=None) -> dict | None:
    """Edit a single transaction. Returns None if deleted."""
    valid_types = ["buy", "sell", "dividend", "interest", "deposit", "withdrawal"]

    while True:
        _preview_single_transaction(txn, 0)
        choice = input("\nEnter number to edit (or Enter to finish): ").strip()

        if not choice:
            return txn

        try:
            field_num = int(choice)
        except ValueError:
            print(f"{RED}Please enter a number{RESET}")
            continue

        if field_num == 1:  # Type
            print("\nSelect type:")
            for i, t in enumerate(valid_types, 1):
                print(f"  {BLUE}{i}{RESET}. {t}")
            try:
                type_choice = input(f"Type [current: {txn.get('type', '?')}]: ").strip()
                if type_choice:
                    idx = int(type_choice)
                    if 1 <= idx <= len(valid_types):
                        txn["type"] = valid_types[idx - 1]
            except ValueError:
                print(f"  {RED}Invalid choice{RESET}")

        elif field_num == 2:  # Date
            new_date = input(f"Date (YYYY-MM-DD) [{txn.get('date', '')}]: ").strip()
            if new_date:
                txn["date"] = new_date

        elif field_num == 3:  # Security
            new_security = input(f"Security [{txn.get('security', '')}]: ").strip()
            if new_security:
                txn["security"] = new_security

        elif field_num == 4:  # Quantity
            qty_str = input(f"Quantity [{txn.get('quantity', '')}]: ").strip()
            if qty_str:
                try:
                    txn["quantity"] = int(qty_str)
                except ValueError:
                    print(f"  {RED}Invalid quantity{RESET}")

        elif field_num == 5:  # Unit price
            currency = txn.get("currency", "EUR")
            txn["unit_price_cents"] = _input_cents(
                "Unit price", txn.get("unit_price_cents"), currency
            )

        elif field_num == 6:  # Fees (always EUR)
            txn["cost_cents"] = _input_cents("Fees", txn.get("cost_cents", 0), "EUR")

        elif field_num == 7:  # Confidence
            print("\nSelect confidence:")
            for i, c in enumerate(["high", "medium", "low"], 1):
                print(f"  {BLUE}{i}{RESET}. {c}")
            try:
                conf_choice = input(
                    f"Confidence [current: {txn.get('confidence', '?')}]: "
                ).strip()
                if conf_choice:
                    idx = int(conf_choice)
                    if 1 <= idx <= 3:
                        txn["confidence"] = ["high", "medium", "low"][idx - 1]
            except ValueError:
                print(f"  {RED}Invalid choice{RESET}")

        elif field_num == 8:  # Currency
            print("\nCommon currencies: EUR, USD, GBP, CHF")
            new_currency = (
                input(f"Currency [{txn.get('currency', 'EUR')}]: ").strip().upper()
            )
            if new_currency:
                txn["currency"] = new_currency

        elif field_num == 9:  # Exchange rate
            current_rate = txn.get("exchange_rate", 1.0)
            rate_str = input(f"Exchange rate (to EUR) [{current_rate}]: ").strip()
            if rate_str:
                try:
                    rate = float(rate_str.replace(",", "."))
                    if rate > 0:
                        txn["exchange_rate"] = rate
                    else:
                        print(f"  {RED}Rate must be positive{RESET}")
                except ValueError:
                    print(f"  {RED}Invalid rate{RESET}")

        elif field_num == 10:  # Delete
            confirm = (
                input(f"{RED}Delete this transaction? (y/N): {RESET}").strip().lower()
            )
            if confirm == "y":
                return None

        else:
            print(f"{RED}Invalid choice. Enter 1-10{RESET}")
