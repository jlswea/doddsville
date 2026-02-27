import requests

from formatting import GREEN, RED, RESET, YELLOW
from paperless import (
    DocumentMetadata,
    fetch_paperless_correspondents,
    fetch_paperless_document_types,
    fetch_paperless_storage_paths,
    fetch_paperless_tags,
    get_or_create_dv_custom_field_id,
    get_paperless_headers,
    insert_transaction_documents,
    resolve_doc_args,
    set_document_transaction_ids,
)
from ui import edit_document_metadata


def handle_doc(args, config, conn, cur):
    """Handle the 'doc' command."""
    if args.doc_action == "add":
        # Verify transaction exists
        cur.execute(
            'SELECT id, type, date FROM "transaction" WHERE id = ?',
            (args.transaction_id,),
        )
        transaction = cur.fetchone()
        if not transaction:
            print(f"{RED}Transaction {args.transaction_id} not found.{RESET}")
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
                try:
                    cf_id = get_or_create_dv_custom_field_id(config)
                    for did in new_docs:
                        set_document_transaction_ids(
                            config, did, cf_id, [args.transaction_id]
                        )
                except Exception as e:
                    print(
                        f"  {YELLOW}Warning: Could not set transaction ID custom field: {e}{RESET}"
                    )
            elif not duplicates:
                print("No documents were linked.")
        else:
            print(f"{RED}No valid documents to link.{RESET}")

        if failed_docs:
            print(f"\n{YELLOW}Failed to process:{RESET}")
            for f in failed_docs:
                print(f"  - {f}")

    elif args.doc_action == "edit":
        doc_id = args.doc_id
        try:
            base_url, headers = get_paperless_headers(config)
        except ValueError as e:
            print(f"{RED}{e}{RESET}")
            return

        # Fetch document
        response = requests.get(
            f"{base_url}/api/documents/{doc_id}/", headers=headers
        )
        if response.status_code == 404:
            print(f"{RED}Document {doc_id} not found in Paperless.{RESET}")
            return
        response.raise_for_status()
        doc = response.json()

        # Fetch metadata options
        correspondents = fetch_paperless_correspondents(config)
        doc_types = fetch_paperless_document_types(config)
        storage_paths = fetch_paperless_storage_paths(config)
        tags = fetch_paperless_tags(config)

        # Build DocumentMetadata from current values
        metadata = DocumentMetadata(
            title=doc.get("title", ""),
            created=doc.get("created", ""),
            correspondent_id=doc.get("correspondent"),
            document_type_id=doc.get("document_type"),
            storage_path_id=doc.get("storage_path"),
            tag_ids=doc.get("tags", []),
            archive_serial_number=str(doc.get("archive_serial_number") or ""),
        )

        metadata = edit_document_metadata(
            metadata, correspondents, doc_types, storage_paths, tags
        )

        # PATCH the document
        patch_data = {
            "title": metadata.title,
            "created": metadata.created or None,
            "correspondent": metadata.correspondent_id,
            "document_type": metadata.document_type_id,
            "storage_path": metadata.storage_path_id,
            "tags": metadata.tag_ids,
        }
        if metadata.archive_serial_number:
            patch_data["archive_serial_number"] = metadata.archive_serial_number

        patch_response = requests.patch(
            f"{base_url}/api/documents/{doc_id}/",
            headers=headers,
            json=patch_data,
        )
        patch_response.raise_for_status()
        print(f"{GREEN}Document {doc_id} updated.{RESET}")

        # Ensure dv_transaction_id custom field is set (backlink from paperless to dv)
        cur.execute(
            "SELECT transaction_id FROM transaction_document WHERE paperless_id = ?",
            (doc_id,),
        )
        linked_txn_ids = [row[0] for row in cur.fetchall()]
        if linked_txn_ids:
            try:
                cf_id = get_or_create_dv_custom_field_id(config)
                # Check if field is already set on the document
                has_field = any(
                    cf.get("field") == cf_id and cf.get("value")
                    for cf in doc.get("custom_fields", [])
                )
                if not has_field:
                    set_document_transaction_ids(
                        config, doc_id, cf_id, linked_txn_ids
                    )
                    print(
                        f"  Set dv_transaction_id: {','.join(str(i) for i in linked_txn_ids)}"
                    )
            except Exception as e:
                print(
                    f"  {YELLOW}Warning: Could not set transaction ID custom field: {e}{RESET}"
                )
