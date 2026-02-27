"""Template-based parser for Scalable Capital documents.

Uses coordinate/position-based extraction for documents with consistent layouts.
Templates define where fields appear on the page, making extraction fast and predictable.
"""
import re
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any, Callable

import pdfplumber

from .base import (
    BaseParser,
    Confidence,
    ParseResult,
    PDFContent,
    Transaction,
    register_parser,
)


class AnchorPosition(Enum):
    """Where to look for value relative to anchor label."""
    RIGHT = "right"      # Same line, to the right
    BELOW = "below"      # Next line, same x position
    RIGHT_BELOW = "right_below"  # Below and to the right (table cell)


@dataclass
class FieldDef:
    """Definition of a field to extract from the document."""
    name: str

    # Option 1: Fixed bounding box (x0, y0, x1, y1) in points
    bbox: tuple[float, float, float, float] | None = None

    # Option 2: Anchor-based extraction
    anchor_label: str | None = None  # Text to search for
    anchor_position: AnchorPosition = AnchorPosition.RIGHT
    anchor_offset_x: float = 0  # Additional x offset from anchor
    anchor_offset_y: float = 0  # Additional y offset from anchor
    search_width: float = 200   # How wide to search for value
    search_height: float = 20   # How tall to search for value

    # Option 3: Regex on page text (fallback)
    pattern: str | None = None
    pattern_group: int = 1  # Which regex group contains the value

    # Parser function to convert extracted string to final value
    parser: Callable[[str], Any] | None = None

    # Which page to look on (0-indexed, None = all pages)
    page: int | None = None

    # Is this field required?
    required: bool = False


@dataclass
class DocumentTemplate:
    """Template for a specific document type."""
    name: str
    # Text that must be present to match this template
    identifiers: list[str] = field(default_factory=list)
    # Fields to extract
    fields: list[FieldDef] = field(default_factory=list)
    # Document classification
    doc_type: str = ""  # "trade", "dividend", etc.


def parse_german_amount(value: str) -> int | None:
    """Parse German number format (1.234,56) to cents."""
    if not value:
        return None
    clean = re.sub(r"[€EUR\s]", "", value.strip())
    try:
        clean = clean.replace(".", "").replace(",", ".")
        return int(float(clean) * 100)
    except ValueError:
        return None


def parse_german_date(value: str) -> str | None:
    """Parse German date (DD.MM.YYYY) to YYYY-MM-DD."""
    match = re.search(r"(\d{2})\.(\d{2})\.(\d{4})", value)
    if match:
        day, month, year = match.groups()
        try:
            date_obj = datetime(int(year), int(month), int(day))
            return date_obj.strftime("%Y-%m-%d")
        except ValueError:
            return None
    return None


def parse_quantity(value: str) -> int | None:
    """Parse quantity string to integer."""
    if not value:
        return None
    clean = re.sub(r"[^\d,.]", "", value)
    try:
        clean = clean.replace(".", "").replace(",", ".")
        return int(float(clean))
    except ValueError:
        return None


# Template definitions for Scalable Capital documents
SCALABLE_TRADE_BUY_TEMPLATE = DocumentTemplate(
    name="scalable_trade_buy",
    identifiers=["scalable capital", "wertpapierabrechnung", "kauf"],
    doc_type="trade_buy",
    fields=[
        # Company name - usually appears before ISIN
        FieldDef(
            name="company",
            anchor_label="ISIN",
            anchor_position=AnchorPosition.BELOW,
            anchor_offset_y=-25,  # Look above ISIN
            search_width=300,
            search_height=20,
            page=0,
        ),
        # ISIN code
        FieldDef(
            name="isin",
            pattern=r"([A-Z]{2}[A-Z0-9]{10})",
            page=0,
        ),
        # Quantity (Stück)
        FieldDef(
            name="quantity",
            anchor_label="Stück",
            anchor_position=AnchorPosition.RIGHT,
            search_width=100,
            parser=parse_quantity,
            page=0,
        ),
        # Alternative: quantity before "Stück"
        FieldDef(
            name="quantity_alt",
            pattern=r"(\d+(?:[.,]\d+)?)\s*Stück",
            parser=parse_quantity,
        ),
        # Unit price (Kurs/Ausführungskurs)
        FieldDef(
            name="unit_price",
            anchor_label="Kurs",
            anchor_position=AnchorPosition.RIGHT,
            search_width=150,
            parser=parse_german_amount,
            page=0,
        ),
        # Total value (Kurswert)
        FieldDef(
            name="total",
            anchor_label="Kurswert",
            anchor_position=AnchorPosition.RIGHT,
            search_width=150,
            parser=parse_german_amount,
            required=True,
        ),
        # Alternative: Ausmachender Betrag
        FieldDef(
            name="total_alt",
            anchor_label="Ausmachender Betrag",
            anchor_position=AnchorPosition.RIGHT,
            search_width=150,
            parser=parse_german_amount,
        ),
        # Transaction date (Schlusstag/Valuta)
        FieldDef(
            name="date",
            anchor_label="Schlusstag",
            anchor_position=AnchorPosition.RIGHT,
            search_width=120,
            parser=parse_german_date,
            required=True,
        ),
        # Alternative date field
        FieldDef(
            name="date_alt",
            anchor_label="Valuta",
            anchor_position=AnchorPosition.RIGHT,
            search_width=120,
            parser=parse_german_date,
        ),
        # Fees (Provision/Gebühren)
        FieldDef(
            name="fees",
            anchor_label="Provision",
            anchor_position=AnchorPosition.RIGHT,
            search_width=150,
            parser=parse_german_amount,
        ),
    ],
)

SCALABLE_TRADE_SELL_TEMPLATE = DocumentTemplate(
    name="scalable_trade_sell",
    identifiers=["scalable capital", "wertpapierabrechnung", "verkauf"],
    doc_type="trade_sell",
    fields=SCALABLE_TRADE_BUY_TEMPLATE.fields,  # Same fields as buy
)

SCALABLE_DIVIDEND_TEMPLATE = DocumentTemplate(
    name="scalable_dividend",
    identifiers=["scalable capital", "dividende"],
    doc_type="dividend",
    fields=[
        # Company name
        FieldDef(
            name="company",
            anchor_label="ISIN",
            anchor_position=AnchorPosition.BELOW,
            anchor_offset_y=-25,
            search_width=300,
            search_height=20,
            page=0,
        ),
        # ISIN
        FieldDef(
            name="isin",
            pattern=r"([A-Z]{2}[A-Z0-9]{10})",
            page=0,
        ),
        # Dividend amount (Ausmachender Betrag)
        FieldDef(
            name="total",
            anchor_label="Ausmachender Betrag",
            anchor_position=AnchorPosition.RIGHT,
            search_width=150,
            parser=parse_german_amount,
            required=True,
        ),
        # Alternative: Nettobetrag
        FieldDef(
            name="total_alt",
            anchor_label="Nettobetrag",
            anchor_position=AnchorPosition.RIGHT,
            search_width=150,
            parser=parse_german_amount,
        ),
        # Payment date
        FieldDef(
            name="date",
            anchor_label="Valuta",
            anchor_position=AnchorPosition.RIGHT,
            search_width=120,
            parser=parse_german_date,
            required=True,
        ),
        # Withholding tax
        FieldDef(
            name="tax_kapital",
            anchor_label="Kapitalertragsteuer",
            anchor_position=AnchorPosition.RIGHT,
            search_width=150,
            parser=parse_german_amount,
        ),
        FieldDef(
            name="tax_soli",
            anchor_label="Solidaritätszuschlag",
            anchor_position=AnchorPosition.RIGHT,
            search_width=150,
            parser=parse_german_amount,
        ),
        FieldDef(
            name="tax_quellen",
            anchor_label="Quellensteuer",
            anchor_position=AnchorPosition.RIGHT,
            search_width=150,
            parser=parse_german_amount,
        ),
    ],
)

# All available templates
TEMPLATES = [
    SCALABLE_TRADE_BUY_TEMPLATE,
    SCALABLE_TRADE_SELL_TEMPLATE,
    SCALABLE_DIVIDEND_TEMPLATE,
]


class TemplateExtractor:
    """Extracts fields from a PDF using template definitions."""

    def __init__(self, pdf_path: str):
        self.pdf_path = pdf_path
        self._pdf = None
        self._pages = []
        self._words_by_page: dict[int, list[dict]] = {}

    def __enter__(self):
        self._pdf = pdfplumber.open(self.pdf_path)
        self._pages = self._pdf.pages
        return self

    def __exit__(self, *args):
        if self._pdf:
            self._pdf.close()

    def _get_words(self, page_idx: int) -> list[dict]:
        """Get words for a page, caching the result."""
        if page_idx not in self._words_by_page:
            if page_idx < len(self._pages):
                self._words_by_page[page_idx] = self._pages[page_idx].extract_words()
            else:
                self._words_by_page[page_idx] = []
        return self._words_by_page[page_idx]

    def _find_anchor(self, label: str, page_idx: int | None = None) -> dict | None:
        """Find a word matching the anchor label."""
        label_lower = label.lower()

        pages_to_search = (
            [page_idx] if page_idx is not None
            else range(len(self._pages))
        )

        for p in pages_to_search:
            words = self._get_words(p)
            for word in words:
                if label_lower in word["text"].lower():
                    return {**word, "page": p}

        return None

    def _extract_at_region(
        self,
        page_idx: int,
        x0: float,
        y0: float,
        x1: float,
        y1: float
    ) -> str:
        """Extract text from a specific region of the page."""
        if page_idx >= len(self._pages):
            return ""

        page = self._pages[page_idx]

        # Clamp coordinates to page bounds
        x0 = max(0, x0)
        y0 = max(0, y0)
        x1 = min(page.width, x1)
        y1 = min(page.height, y1)

        try:
            cropped = page.within_bbox((x0, y0, x1, y1))
            text = cropped.extract_text() or ""
            return text.strip()
        except Exception:
            return ""

    def _extract_by_anchor(self, field_def: FieldDef) -> str | None:
        """Extract value based on anchor label position."""
        if not field_def.anchor_label:
            return None

        anchor = self._find_anchor(field_def.anchor_label, field_def.page)
        if not anchor:
            return None

        page_idx = anchor["page"]

        # Calculate search region based on anchor position
        if field_def.anchor_position == AnchorPosition.RIGHT:
            # Search to the right of the anchor
            x0 = anchor["x1"] + field_def.anchor_offset_x
            y0 = anchor["top"] + field_def.anchor_offset_y
            x1 = x0 + field_def.search_width
            y1 = y0 + field_def.search_height

        elif field_def.anchor_position == AnchorPosition.BELOW:
            # Search below the anchor
            x0 = anchor["x0"] + field_def.anchor_offset_x
            y0 = anchor["bottom"] + field_def.anchor_offset_y
            x1 = x0 + field_def.search_width
            y1 = y0 + field_def.search_height

        elif field_def.anchor_position == AnchorPosition.RIGHT_BELOW:
            # Search below and to the right (table cell pattern)
            x0 = anchor["x1"] + field_def.anchor_offset_x
            y0 = anchor["bottom"] + field_def.anchor_offset_y
            x1 = x0 + field_def.search_width
            y1 = y0 + field_def.search_height

        else:
            return None

        return self._extract_at_region(page_idx, x0, y0, x1, y1)

    def _extract_by_bbox(self, field_def: FieldDef) -> str | None:
        """Extract value from a fixed bounding box."""
        if not field_def.bbox:
            return None

        page_idx = field_def.page or 0
        x0, y0, x1, y1 = field_def.bbox

        return self._extract_at_region(page_idx, x0, y0, x1, y1)

    def _extract_by_pattern(self, field_def: FieldDef, full_text: str) -> str | None:
        """Extract value using regex pattern."""
        if not field_def.pattern:
            return None

        # If page is specified, only search that page
        if field_def.page is not None and field_def.page < len(self._pages):
            page_text = self._pages[field_def.page].extract_text() or ""
        else:
            page_text = full_text

        match = re.search(field_def.pattern, page_text, re.IGNORECASE)
        if match:
            try:
                return match.group(field_def.pattern_group)
            except IndexError:
                return match.group(0)

        return None

    def extract_field(self, field_def: FieldDef, full_text: str) -> Any:
        """Extract a single field using the appropriate method."""
        value = None

        # Try extraction methods in order of preference
        if field_def.bbox:
            value = self._extract_by_bbox(field_def)

        if not value and field_def.anchor_label:
            value = self._extract_by_anchor(field_def)

        if not value and field_def.pattern:
            value = self._extract_by_pattern(field_def, full_text)

        # Apply parser if value found and parser defined
        if value and field_def.parser:
            try:
                value = field_def.parser(value)
            except Exception:
                value = None

        return value

    def extract_all(self, template: DocumentTemplate, full_text: str) -> dict[str, Any]:
        """Extract all fields defined in a template."""
        results = {}

        for field_def in template.fields:
            value = self.extract_field(field_def, full_text)
            if value is not None:
                # Handle alternative fields (field_alt -> field if field is empty)
                base_name = field_def.name.replace("_alt", "")
                if field_def.name.endswith("_alt"):
                    if base_name not in results or results[base_name] is None:
                        results[base_name] = value
                else:
                    results[field_def.name] = value

        return results


@register_parser
class ScalableTemplateParser(BaseParser):
    """Template-based parser for Scalable Capital documents.

    Uses positional extraction based on document templates.
    Most efficient for documents with consistent layouts.
    """

    name = "scalable_template"

    # Static Paperless config
    correspondent = "Scalable Capital"
    document_type = "Abrechnung"
    storage_path = None
    tags = []

    def __init__(self):
        super().__init__()
        self._pdf_path: str | None = None

    def set_pdf_path(self, path: str) -> None:
        """Set the PDF path for coordinate-based extraction."""
        self._pdf_path = path

    def can_parse(self, content: PDFContent) -> tuple[bool, Confidence]:
        """Check if this is a Scalable Capital document."""
        text_lower = content.text.lower()

        if "scalable capital" not in text_lower:
            return False, Confidence.LOW

        # Check if any template matches
        for template in TEMPLATES:
            if all(ident in text_lower for ident in template.identifiers):
                return True, Confidence.HIGH

        return False, Confidence.LOW

    def parse(self, content: PDFContent, config: dict) -> ParseResult | None:
        """Parse document using template-based extraction."""
        text_lower = content.text.lower()

        # Find matching template
        template = self._match_template(text_lower)
        if not template:
            return None

        # We need the PDF path for coordinate extraction
        pdf_path = config.get("_pdf_path")
        if not pdf_path:
            # Fall back to pattern-only extraction
            return self._parse_pattern_only(content, template)

        # Extract fields using template
        with TemplateExtractor(pdf_path) as extractor:
            fields = extractor.extract_all(template, content.text)

        # Supplement with pattern extraction for missing fields
        fields = self._supplement_fields(fields, content.text, template)

        # Build transaction
        transaction = self._build_transaction(fields, template)
        if not transaction:
            return None

        # Build metadata
        company = fields.get("company", "Unknown")
        date_str = fields.get("date", "")

        if template.doc_type == "trade_buy":
            title = f"Wertpapierabrechnung Kauf {company}"
        elif template.doc_type == "trade_sell":
            title = f"Wertpapierabrechnung Verkauf {company}"
        elif template.doc_type == "dividend":
            title = f"Dividendenabrechnung {company}"
        else:
            title = f"Scalable Capital Dokument {date_str}"

        metadata = self.build_metadata(title=title, created=date_str)

        return ParseResult(
            transactions=[transaction],
            metadata=metadata,
            parser_name=self.name,
            confidence=Confidence.HIGH,
        )

    def _match_template(self, text_lower: str) -> DocumentTemplate | None:
        """Find the template that matches this document."""
        for template in TEMPLATES:
            if all(ident in text_lower for ident in template.identifiers):
                return template
        return None

    def _parse_pattern_only(
        self,
        content: PDFContent,
        template: DocumentTemplate
    ) -> ParseResult | None:
        """Fallback: extract using only regex patterns from template."""
        fields = {}

        for field_def in template.fields:
            if field_def.pattern:
                match = re.search(field_def.pattern, content.text, re.IGNORECASE)
                if match:
                    try:
                        value = match.group(field_def.pattern_group)
                        if field_def.parser:
                            value = field_def.parser(value)

                        base_name = field_def.name.replace("_alt", "")
                        if field_def.name.endswith("_alt"):
                            if base_name not in fields:
                                fields[base_name] = value
                        else:
                            fields[field_def.name] = value
                    except (IndexError, Exception):
                        pass

        # Supplement missing required fields
        fields = self._supplement_fields(fields, content.text, template)

        transaction = self._build_transaction(fields, template)
        if not transaction:
            return None

        company = fields.get("company", "Unknown")
        date_str = fields.get("date", "")

        if template.doc_type.startswith("trade"):
            trade_type = "Kauf" if "buy" in template.doc_type else "Verkauf"
            title = f"Wertpapierabrechnung {trade_type} {company}"
        else:
            title = f"Dividendenabrechnung {company}"

        metadata = self.build_metadata(title=title, created=date_str)

        return ParseResult(
            transactions=[transaction],
            metadata=metadata,
            parser_name=self.name,
            confidence=Confidence.MEDIUM,  # Lower confidence without coordinates
        )

    def _supplement_fields(
        self,
        fields: dict,
        text: str,
        template: DocumentTemplate
    ) -> dict:
        """Fill in missing fields using fallback patterns."""
        # Company name from ISIN context
        if "company" not in fields or not fields["company"]:
            isin_match = re.search(r"([A-Z]{2}[A-Z0-9]{10})", text)
            if isin_match:
                before = text[:isin_match.start()]
                lines = before.strip().split("\n")
                for line in reversed(lines[-5:]):
                    line = line.strip()
                    if line and len(line) > 3:
                        skip = ["wertpapierabrechnung", "kauf", "verkauf",
                               "stück", "depotnummer", "seite", "datum", "scalable"]
                        if not any(s in line.lower() for s in skip):
                            fields["company"] = line
                            break

        # Date fallback
        if "date" not in fields or not fields["date"]:
            for pattern in [
                r"Valuta[:\s]*(\d{2}\.\d{2}\.\d{4})",
                r"Schlusstag[:\s]*(\d{2}\.\d{2}\.\d{4})",
                r"(\d{2}\.\d{2}\.\d{4})",
            ]:
                match = re.search(pattern, text, re.IGNORECASE)
                if match:
                    fields["date"] = parse_german_date(match.group(1))
                    if fields["date"]:
                        break

        # Total fallback
        if "total" not in fields or not fields["total"]:
            for pattern in [
                r"Kurswert[:\s]*([\d.,]+)\s*(?:EUR|€)?",
                r"Ausmachender Betrag[:\s]*([\d.,]+)",
                r"Nettobetrag[:\s]*([\d.,]+)",
            ]:
                match = re.search(pattern, text, re.IGNORECASE)
                if match:
                    fields["total"] = parse_german_amount(match.group(1))
                    if fields["total"]:
                        break

        return fields

    def _build_transaction(
        self,
        fields: dict,
        template: DocumentTemplate
    ) -> Transaction | None:
        """Build a transaction from extracted fields."""
        company = fields.get("company")
        total = fields.get("total")
        date_str = fields.get("date")

        if not all([total, date_str]):
            return None

        unit_price = fields.get("unit_price")
        quantity = fields.get("quantity")

        if template.doc_type == "trade_buy":
            # Use unit_price and quantity if available, otherwise derive from total
            if unit_price and quantity:
                return Transaction(
                    type="buy",
                    date=date_str,
                    unit_price_cents=unit_price,
                    quantity=quantity,
                    security=company,
                    cost_cents=fields.get("fees", 0),
                    confidence=Confidence.HIGH,
                    description="Scalable Capital buy (template parser)",
                )
            else:
                return Transaction(
                    type="buy",
                    date=date_str,
                    unit_price_cents=total,
                    quantity=1,
                    security=company,
                    cost_cents=fields.get("fees", 0),
                    confidence=Confidence.MEDIUM,
                    description="Scalable Capital buy (template parser)",
                )

        elif template.doc_type == "trade_sell":
            if unit_price and quantity:
                return Transaction(
                    type="sell",
                    date=date_str,
                    unit_price_cents=unit_price,
                    quantity=quantity,
                    security=company,
                    cost_cents=fields.get("fees", 0),
                    confidence=Confidence.HIGH,
                    description="Scalable Capital sell (template parser)",
                )
            else:
                return Transaction(
                    type="sell",
                    date=date_str,
                    unit_price_cents=total,
                    quantity=1,
                    security=company,
                    cost_cents=fields.get("fees", 0),
                    confidence=Confidence.MEDIUM,
                    description="Scalable Capital sell (template parser)",
                )

        elif template.doc_type == "dividend":
            # Sum all tax fields
            tax = sum(filter(None, [
                fields.get("tax_kapital"),
                fields.get("tax_soli"),
                fields.get("tax_quellen"),
            ]))

            # Use total as unit_price with quantity=1 for dividends
            return Transaction(
                type="dividend",
                date=date_str,
                unit_price_cents=total,
                quantity=1,
                security=company,
                cost_cents=tax,
                confidence=Confidence.HIGH,
                description="Scalable Capital dividend (template parser)",
            )

        return None
