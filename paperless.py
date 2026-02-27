import time
from dataclasses import dataclass, field
from pathlib import Path

import requests

from formatting import GREEN, RED, RESET, format_cents


def get_paperless_headers(config: dict) -> tuple:
    """Get base URL and auth headers for paperless API."""
    url = config.get("paperless_url")
    token = config.get("paperless_token")

    if not url or not token:
        raise ValueError("paperless_url and paperless_token must be configured")

    return url.rstrip("/"), {"Authorization": f"Token {token}"}


def verify_document_exists(doc_id: int, config: dict) -> bool:
    """Verify a document ID exists in paperless-ngx."""
    base_url, headers = get_paperless_headers(config)
    response = requests.get(f"{base_url}/api/documents/{doc_id}/", headers=headers)
    return response.status_code == 200


@dataclass
class DocumentMetadata:
    """Metadata for uploading documents to Paperless-ngx."""

    title: str = ""
    created: str = ""  # YYYY-MM-DD format
    correspondent_id: int | None = None
    document_type_id: int | None = None
    storage_path_id: int | None = None
    tag_ids: list[int] = field(default_factory=list)
    archive_serial_number: str = ""


def fetch_paperless_correspondents(config: dict) -> list[dict]:
    """Fetch all correspondents from Paperless-ngx."""
    base_url, headers = get_paperless_headers(config)
    response = requests.get(
        f"{base_url}/api/correspondents/?page_size=1000", headers=headers
    )
    response.raise_for_status()
    results = response.json().get("results", [])
    return [{"id": r["id"], "name": r["name"]} for r in results]


def fetch_paperless_document_types(config: dict) -> list[dict]:
    """Fetch all document types from Paperless-ngx."""
    base_url, headers = get_paperless_headers(config)
    response = requests.get(
        f"{base_url}/api/document_types/?page_size=1000", headers=headers
    )
    response.raise_for_status()
    results = response.json().get("results", [])
    return [{"id": r["id"], "name": r["name"]} for r in results]


def fetch_paperless_storage_paths(config: dict) -> list[dict]:
    """Fetch all storage paths from Paperless-ngx."""
    base_url, headers = get_paperless_headers(config)
    response = requests.get(
        f"{base_url}/api/storage_paths/?page_size=1000", headers=headers
    )
    response.raise_for_status()
    results = response.json().get("results", [])
    return [{"id": r["id"], "name": r["name"]} for r in results]


def fetch_paperless_tags(config: dict) -> list[dict]:
    """Fetch all tags from Paperless-ngx."""
    base_url, headers = get_paperless_headers(config)
    response = requests.get(f"{base_url}/api/tags/?page_size=1000", headers=headers)
    response.raise_for_status()
    results = response.json().get("results", [])
    return [{"id": r["id"], "name": r["name"]} for r in results]


def get_dv_tag_id(config: dict) -> int | None:
    """Get the 'dv' tag ID from Paperless-ngx, or None if not found."""
    tags = fetch_paperless_tags(config)
    for tag in tags:
        if tag["name"] == "dv":
            return tag["id"]
    return None


def upload_document_to_paperless(
    file_path: str,
    config: dict,
    dv_tag_id: int,
    metadata: DocumentMetadata | None = None,
    remove_tag_ids: list[int] | None = None,
) -> int:
    """Upload a document to paperless-ngx and return the document ID.

    The dv_tag_id is required and will always be applied to uploaded documents.
    If remove_tag_ids is provided, those tags will be removed after upload
    (paperless may add them automatically via workflows).
    """
    base_url, headers = get_paperless_headers(config)

    # Build form data with metadata
    form_data = []
    if metadata:
        if metadata.title:
            form_data.append(("title", (None, metadata.title)))
        if metadata.created:
            form_data.append(("created", (None, metadata.created)))
        if metadata.correspondent_id:
            form_data.append(("correspondent", (None, str(metadata.correspondent_id))))
        if metadata.document_type_id:
            form_data.append(("document_type", (None, str(metadata.document_type_id))))
        if metadata.storage_path_id:
            form_data.append(("storage_path", (None, str(metadata.storage_path_id))))
        for tag_id in metadata.tag_ids:
            if tag_id != dv_tag_id:  # Avoid duplicate
                form_data.append(("tags", (None, str(tag_id))))
        if metadata.archive_serial_number:
            form_data.append(
                ("archive_serial_number", (None, metadata.archive_serial_number))
            )

    # Always add the 'dv' tag
    form_data.append(("tags", (None, str(dv_tag_id))))

    # Upload document (returns task UUID)
    with open(file_path, "rb") as f:
        files = [("document", (Path(file_path).name, f))] + form_data
        response = requests.post(
            f"{base_url}/api/documents/post_document/", headers=headers, files=files
        )
    response.raise_for_status()
    task_id = response.text.strip('"')  # Returns UUID as quoted string

    # Poll for task completion to get document ID
    doc_id = None
    for _ in range(120):  # Max 2 minutes for OCR processing
        time.sleep(1)
        task_response = requests.get(
            f"{base_url}/api/tasks/?task_id={task_id}", headers=headers
        )
        task_response.raise_for_status()
        tasks = task_response.json()

        if tasks and tasks[0].get("status") == "SUCCESS":
            doc_id = tasks[0]["related_document"]
            break
        elif tasks and tasks[0].get("status") == "FAILURE":
            raise RuntimeError(f"Document upload failed: {tasks[0].get('result')}")

    if doc_id is None:
        raise TimeoutError(
            "Document was uploaded but timed out waiting for paperless to finish processing. "
            "Check paperless inbox for the document."
        )

    # Remove workflow tags if present (paperless may add them automatically)
    if remove_tag_ids:
        doc_response = requests.get(
            f"{base_url}/api/documents/{doc_id}/", headers=headers
        )
        doc_response.raise_for_status()
        doc_data = doc_response.json()
        current_tags = doc_data.get("tags", [])
        tags_to_remove = [tid for tid in remove_tag_ids if tid in current_tags]
        if tags_to_remove:
            for tid in tags_to_remove:
                current_tags.remove(tid)
            requests.patch(
                f"{base_url}/api/documents/{doc_id}/",
                headers=headers,
                json={"tags": current_tags},
            )

    return doc_id


def get_or_create_dv_custom_field_id(config: dict) -> int:
    """Get or create the 'dv_transaction_id' custom field in Paperless-ngx. Returns the field ID."""
    base_url, headers = get_paperless_headers(config)
    response = requests.get(
        f"{base_url}/api/custom_fields/?page_size=1000", headers=headers
    )
    response.raise_for_status()
    for cf in response.json().get("results", []):
        if cf["name"] == "dv_transaction_id":
            return cf["id"]
    # Not found — create it
    response = requests.post(
        f"{base_url}/api/custom_fields/",
        headers=headers,
        json={"name": "dv_transaction_id", "data_type": "string"},
    )
    response.raise_for_status()
    return response.json()["id"]


def set_document_transaction_ids(
    config: dict, doc_id: int, field_id: int, transaction_ids: list[int]
):
    """Set or merge dv_transaction_id custom field on a Paperless document."""
    base_url, headers = get_paperless_headers(config)
    # Fetch current custom fields on the document
    response = requests.get(
        f"{base_url}/api/documents/{doc_id}/", headers=headers
    )
    response.raise_for_status()
    doc_data = response.json()

    # Parse existing value and merge
    existing_ids: set[int] = set()
    for cf in doc_data.get("custom_fields", []):
        if cf.get("field") == field_id and cf.get("value"):
            for part in str(cf["value"]).split(","):
                part = part.strip()
                if part.isdigit():
                    existing_ids.add(int(part))

    merged = sorted(existing_ids | set(transaction_ids))
    merged_str = ",".join(str(i) for i in merged)

    # Build custom_fields payload preserving other fields
    new_custom_fields = [
        cf for cf in doc_data.get("custom_fields", []) if cf.get("field") != field_id
    ]
    new_custom_fields.append({"field": field_id, "value": merged_str})

    requests.patch(
        f"{base_url}/api/documents/{doc_id}/",
        headers=headers,
        json={"custom_fields": new_custom_fields},
    ).raise_for_status()


def resolve_doc_args(doc_args: list, config: dict) -> tuple:
    """
    Resolve --doc arguments to paperless document IDs.
    Returns: (successful_doc_ids, failed_args)
    - Integers are verified via API before adding
    - File paths are uploaded and the new document ID is returned
    - Failures are collected but don't stop processing
    """
    doc_ids = []
    failed = []

    # Check if any files need uploading
    files_to_upload = [
        arg for arg in doc_args if not arg.isdigit() and Path(arg).exists()
    ]

    # Get required IDs if we have files to upload
    dv_tag_id = None
    remove_tag_ids = []
    abrechnung_doc_type_id = None
    if files_to_upload:
        tags = fetch_paperless_tags(config)
        for tag in tags:
            if tag["name"] == "dv":
                dv_tag_id = tag["id"]
            elif tag["name"] in ("todo", "inbox"):
                remove_tag_ids.append(tag["id"])

        doc_types = fetch_paperless_document_types(config)
        for dt in doc_types:
            if dt["name"] == "Abrechnung":
                abrechnung_doc_type_id = dt["id"]
                break

        # Check required items
        missing = []
        if dv_tag_id is None:
            missing.append("tag 'dv'")
        if abrechnung_doc_type_id is None:
            missing.append("document type 'Abrechnung'")

        if missing:
            print(
                f"{RED}✗ Cannot upload: {', '.join(missing)} not found in paperless-ngx.{RESET}"
            )
            print(
                "  Please create the missing item(s) in paperless before uploading documents."
            )
            return [], doc_args  # All args failed

    for arg in doc_args:
        try:
            if arg.isdigit():
                doc_id = int(arg)
                print(f"Verifying document {doc_id}...")
                if verify_document_exists(doc_id, config):
                    doc_ids.append(doc_id)
                    print(f"  {GREEN}✓{RESET} Document {doc_id} exists")
                else:
                    print(f"  {RED}✗{RESET} Document {doc_id} not found in paperless")
                    failed.append(arg)
            elif Path(arg).exists():
                print(f"Uploading {arg} to paperless-ngx...")
                metadata = DocumentMetadata(
                    tag_ids=[dv_tag_id],
                    document_type_id=abrechnung_doc_type_id,
                )
                doc_id = upload_document_to_paperless(
                    arg, config, dv_tag_id, metadata, remove_tag_ids
                )
                print(f"  {GREEN}✓{RESET} Uploaded as document {doc_id}")
                doc_ids.append(doc_id)
            else:
                print(f"  {RED}✗{RESET} {arg} is not a valid ID or file path")
                failed.append(arg)
        except Exception as e:
            print(f"  {RED}✗{RESET} Failed: {e}")
            failed.append(arg)

    return doc_ids, failed


def insert_transaction_documents(cur, transaction_id: int, doc_ids: list):
    """Link paperless document IDs to a transaction."""
    for doc_id in doc_ids:
        cur.execute(
            "INSERT INTO transaction_document (transaction_id, paperless_id) VALUES (?, ?)",
            (transaction_id, doc_id),
        )


def check_paperless_connection(config: dict) -> tuple:
    """
    Check if paperless-ngx API is reachable and configured correctly.
    Returns: (success: bool, message: str, details: dict)
    """
    url = config.get("paperless_url")
    token = config.get("paperless_token")

    details = {
        "url_configured": bool(url),
        "token_configured": bool(token),
    }

    if not url:
        return False, "paperless_url not configured", details
    if not token:
        return False, "paperless_token not configured", details

    base_url = url.rstrip("/")
    headers = {"Authorization": f"Token {token}"}

    try:
        # Check API root
        response = requests.get(f"{base_url}/api/", headers=headers, timeout=10)
        details["status_code"] = response.status_code
        details["response_time_ms"] = int(response.elapsed.total_seconds() * 1000)

        if response.status_code == 200:
            # Try to get document count
            docs_response = requests.get(
                f"{base_url}/api/documents/", headers=headers, timeout=10
            )
            if docs_response.status_code == 200:
                data = docs_response.json()
                details["document_count"] = data.get("count", "unknown")
            return True, "Connection successful", details
        elif response.status_code == 401:
            return False, "Authentication failed - check your token", details
        elif response.status_code == 403:
            return False, "Access forbidden - check token permissions", details
        else:
            return False, f"Unexpected status code: {response.status_code}", details

    except requests.exceptions.ConnectionError:
        return False, f"Cannot connect to {base_url}", details
    except requests.exceptions.Timeout:
        return False, "Connection timed out", details
    except requests.exceptions.RequestException as e:
        return False, f"Request error: {e}", details


# PDF Import helper functions


def resolve_correspondent(name: str | None, correspondents: list[dict]) -> int | None:
    """Resolve correspondent name to ID."""
    if not name:
        return None
    name_lower = name.lower()
    for corr in correspondents:
        if name_lower in corr["name"].lower() or corr["name"].lower() in name_lower:
            return corr["id"]
    return None


def resolve_document_type(name: str | None, doc_types: list[dict]) -> int | None:
    """Resolve document type name to ID."""
    if not name:
        return None
    name_lower = name.lower()
    for dt in doc_types:
        if dt["name"].lower() == name_lower:
            return dt["id"]
    return None


def resolve_storage_path(name: str | None, storage_paths: list[dict]) -> int | None:
    """Resolve storage path name to ID."""
    if not name:
        return None
    name_lower = name.lower()
    for sp in storage_paths:
        if sp["name"].lower() == name_lower:
            return sp["id"]
    return None


def resolve_tags(names: list[str], tags: list[dict]) -> list[int]:
    """Resolve tag names to IDs."""
    if not names:
        return []
    tag_ids = []
    for name in names:
        name_lower = name.lower()
        for tag in tags:
            if tag["name"].lower() == name_lower:
                tag_ids.append(tag["id"])
                break
    return tag_ids


def transaction_to_dict(txn) -> dict:
    """Convert a Transaction dataclass to a dict for compatibility with existing preview/edit functions."""
    return {
        "type": txn.type,
        "date": txn.date,
        "security": txn.security,
        "quantity": txn.quantity,
        "unit_price_cents": txn.unit_price_cents,
        "cost_cents": txn.cost_cents,
        "confidence": txn.confidence.value
        if hasattr(txn.confidence, "value")
        else txn.confidence,
        "description": txn.description,
        "currency": txn.currency,
        "exchange_rate": txn.exchange_rate,
        # Computed values for preview
        "_total_cents": txn.total_value_cents,
        "_total_eur_cents": txn.total_eur_cents,
        "_net_eur_cents": txn.net_eur_cents,
    }
