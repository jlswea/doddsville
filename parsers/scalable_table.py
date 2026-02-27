"""Table-based parser for Scalable Capital documents."""
import re
from datetime import datetime

from .base import (
    BaseParser,
    Confidence,
    ParseResult,
    PDFContent,
    Transaction,
    register_parser,
)


@register_parser
class ScalableTableParser(BaseParser):
    """Table-based parser for Scalable Capital documents.

    Uses structured table data from pdfplumber instead of regex on raw text.
    More reliable for documents with consistent table layouts.
    """

    name = "scalable_table"

    # Static Paperless config
    correspondent = "Scalable Capital"
    document_type = "Abrechnung"
    storage_path = None
    tags = []

    # Known table field labels (German)
    FIELD_LABELS = {
        "isin": ["isin", "wkn"],
        "quantity": ["stück", "anzahl", "nominale"],
        "unit_price": ["kurs", "ausführungskurs", "preis"],
        "total": ["kurswert", "ausmachender betrag", "abrechnungsbetrag", "nettobetrag"],
        "date": ["valuta", "schlusstag", "ausführungstag", "datum"],
        "fees": ["provision", "gebühren", "ordergebühr", "entgelt"],
        "tax": ["kapitalertragsteuer", "quellensteuer", "solidaritätszuschlag"],
    }

    def can_parse(self, content: PDFContent) -> tuple[bool, Confidence]:
        """Check if this is a Scalable Capital document with tables."""
        text_lower = content.text.lower()

        if "scalable capital" not in text_lower:
            return False, Confidence.LOW

        # Prefer this parser if we have tables
        has_tables = len(content.tables) > 0
        is_trade = "wertpapierabrechnung" in text_lower
        is_dividend = "dividendenabrechnung" in text_lower or "dividende" in text_lower

        if has_tables and (is_trade or is_dividend):
            return True, Confidence.HIGH

        return False, Confidence.LOW

    def parse(self, content: PDFContent, config: dict) -> ParseResult | None:
        """Parse Scalable Capital document using table extraction."""
        text_lower = content.text.lower()

        is_trade = "wertpapierabrechnung" in text_lower
        is_dividend = "dividendenabrechnung" in text_lower or (
            "dividende" in text_lower and "wertpapierabrechnung" not in text_lower
        )

        # Extract key-value pairs from all tables
        fields = self._extract_fields_from_tables(content.tables)

        # Also try to extract from text for fields not found in tables
        fields = self._supplement_from_text(fields, content.text)

        transactions = []

        if is_trade:
            txn = self._build_trade_transaction(fields, text_lower)
            if txn:
                transactions.append(txn)
        elif is_dividend:
            txn = self._build_dividend_transaction(fields)
            if txn:
                transactions.append(txn)

        if not transactions:
            return None

        # Build metadata
        company = fields.get("company", "Unknown")
        date_str = fields.get("date", "")

        if is_trade:
            trade_type = "Kauf" if "kauf" in text_lower else "Verkauf"
            title = f"Wertpapierabrechnung {trade_type} {company}"
        elif is_dividend:
            title = f"Dividendenabrechnung {company}"
        else:
            title = f"Scalable Capital Dokument {date_str}"

        metadata = self.build_metadata(title=title, created=date_str)

        return ParseResult(
            transactions=transactions,
            metadata=metadata,
            parser_name=self.name,
            confidence=Confidence.HIGH,
        )

    def _extract_fields_from_tables(self, tables: list[list[list[str]]]) -> dict:
        """Extract key-value pairs from table structures.

        Tables from pdfplumber come as list of rows, each row is list of cells.
        Common patterns:
        - Two-column tables: [label, value]
        - Header row + data rows
        - Mixed label-value pairs
        """
        fields = {}

        for table in tables:
            if not table:
                continue

            for row in table:
                if not row or len(row) < 2:
                    continue

                # Try to match label-value pairs
                self._extract_from_row(row, fields)

        return fields

    def _extract_from_row(self, row: list[str], fields: dict) -> None:
        """Extract field values from a table row."""
        # Clean cells
        cells = [str(cell).strip().lower() if cell else "" for cell in row]
        raw_cells = [str(cell).strip() if cell else "" for cell in row]

        # Check each cell pair for label-value patterns
        for i, cell in enumerate(cells):
            if not cell:
                continue

            # Check if this cell is a known label
            for field_name, labels in self.FIELD_LABELS.items():
                if any(label in cell for label in labels):
                    # Value is likely in the next cell
                    if i + 1 < len(raw_cells) and raw_cells[i + 1]:
                        value = raw_cells[i + 1]
                        self._store_field_value(fields, field_name, value)
                    # Or could be in the same cell after a colon
                    elif ":" in cell:
                        parts = raw_cells[i].split(":", 1)
                        if len(parts) == 2 and parts[1].strip():
                            self._store_field_value(fields, field_name, parts[1].strip())

            # Check for ISIN pattern (12 alphanumeric after 2 letter country code)
            isin_match = re.search(r"[A-Z]{2}[A-Z0-9]{10}", raw_cells[i])
            if isin_match and "isin" not in fields:
                fields["isin"] = isin_match.group()
                # Company name might be in previous cell or same row
                if i > 0 and raw_cells[i - 1]:
                    fields["company"] = raw_cells[i - 1]

    def _store_field_value(self, fields: dict, field_name: str, value: str) -> None:
        """Store a field value, parsing numbers and dates as needed."""
        if field_name == "date":
            parsed_date = self._parse_date(value)
            if parsed_date:
                fields["date"] = parsed_date
        elif field_name in ("quantity", "unit_price", "total", "fees", "tax"):
            parsed_amount = self._parse_amount(value)
            if parsed_amount is not None:
                if field_name in fields:
                    # Accumulate fees and taxes
                    if field_name in ("fees", "tax"):
                        fields[field_name] = fields[field_name] + parsed_amount
                else:
                    fields[field_name] = parsed_amount
        else:
            fields[field_name] = value

    def _supplement_from_text(self, fields: dict, text: str) -> dict:
        """Fill in missing fields from raw text using targeted patterns."""
        # Extract company name if not found in tables
        if "company" not in fields:
            isin_match = re.search(r"([A-Z]{2}[A-Z0-9]{10})", text)
            if isin_match:
                before_isin = text[: isin_match.start()]
                lines = before_isin.strip().split("\n")
                for line in reversed(lines[-5:]):
                    line = line.strip()
                    if line and len(line) > 3:
                        skip_words = ["wertpapierabrechnung", "kauf", "verkauf",
                                     "stück", "depotnummer", "seite", "datum"]
                        if not any(w in line.lower() for w in skip_words):
                            fields["company"] = line
                            break

        # Extract date if not found
        if "date" not in fields:
            date_patterns = [
                r"Valuta[:\s]*(\d{2})\.(\d{2})\.(\d{4})",
                r"Schlusstag[:\s]*(\d{2})\.(\d{2})\.(\d{4})",
                r"(\d{2})\.(\d{2})\.(\d{4})",
            ]
            for pattern in date_patterns:
                match = re.search(pattern, text, re.IGNORECASE)
                if match:
                    day, month, year = match.groups()
                    try:
                        date_obj = datetime(int(year), int(month), int(day))
                        fields["date"] = date_obj.strftime("%Y-%m-%d")
                        break
                    except ValueError:
                        continue

        return fields

    def _build_trade_transaction(self, fields: dict, text_lower: str) -> Transaction | None:
        """Build a trade transaction from extracted fields."""
        txn_type = "buy" if "kauf" in text_lower else "sell"

        company = fields.get("company")
        quantity = fields.get("quantity")
        total = fields.get("total")
        date_str = fields.get("date")

        unit_price = fields.get("unit_price")
        qty = int(quantity) if quantity else 1

        if not all([company, date_str]):
            return None

        # If we have unit_price and quantity, use them; otherwise derive from total
        if unit_price and qty:
            return Transaction(
                type=txn_type,
                date=date_str,
                unit_price_cents=unit_price,
                quantity=qty,
                security=company,
                cost_cents=fields.get("fees", 0),
                confidence=Confidence.HIGH,
                description=f"Scalable Capital {txn_type} (table parser)",
            )
        elif total:
            # Fallback: use total as unit_price with quantity=1
            return Transaction(
                type=txn_type,
                date=date_str,
                unit_price_cents=total,
                quantity=1,
                security=company,
                cost_cents=fields.get("fees", 0),
                confidence=Confidence.MEDIUM,
                description=f"Scalable Capital {txn_type} (table parser)",
            )
        return None

    def _build_dividend_transaction(self, fields: dict) -> Transaction | None:
        """Build a dividend transaction from extracted fields."""
        company = fields.get("company")
        total = fields.get("total")
        date_str = fields.get("date")

        if not all([company, total, date_str]):
            return None

        # Use total as unit_price with quantity=1 for dividends without per-share breakdown
        return Transaction(
            type="dividend",
            date=date_str,
            unit_price_cents=total,
            quantity=1,
            security=company,
            cost_cents=fields.get("tax", 0),
            confidence=Confidence.HIGH,
            description="Scalable Capital dividend (table parser)",
        )

    def _parse_amount(self, value: str) -> int | None:
        """Parse a German-format amount string to cents."""
        if not value:
            return None

        # Remove currency symbols and whitespace
        clean = re.sub(r"[€EUR\s]", "", value)

        # Handle German number format: 1.234,56
        try:
            clean = clean.replace(".", "").replace(",", ".")
            return int(float(clean) * 100)
        except ValueError:
            return None

    def _parse_date(self, value: str) -> str | None:
        """Parse a German date string to YYYY-MM-DD."""
        match = re.search(r"(\d{2})\.(\d{2})\.(\d{4})", value)
        if match:
            day, month, year = match.groups()
            try:
                date_obj = datetime(int(year), int(month), int(day))
                return date_obj.strftime("%Y-%m-%d")
            except ValueError:
                return None
        return None
