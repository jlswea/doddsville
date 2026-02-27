"""Base types and abstract parser class for PDF parsing."""

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Literal

import pdfplumber

DV_TAG = "dv"


class Confidence(Enum):
    """Confidence level for parsing results."""

    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"


@dataclass
class Transaction:
    """Transaction data for database insertion.

    Total value is computed from unit_price_cents * quantity.
    For deposits/withdrawals/interest, use quantity=1 and unit_price_cents=amount.
    """

    type: Literal["buy", "sell", "dividend", "interest", "deposit", "withdrawal"]
    date: str  # YYYY-MM-DD
    unit_price_cents: int  # Unit price in original currency
    quantity: int  # Number of units (use 1 for deposits/withdrawals/interest)
    security: str | None = None
    cost_cents: int = 0  # Fees/taxes in EUR
    confidence: Confidence = Confidence.HIGH
    description: str = ""
    currency: str = "EUR"  # Currency of unit_price_cents
    exchange_rate: float = 1.0  # Multiplier to convert to EUR

    @property
    def total_value_cents(self) -> int:
        """Computed total in original currency."""
        return self.unit_price_cents * self.quantity

    @property
    def total_eur_cents(self) -> int:
        """Computed total in EUR."""
        return int(self.total_value_cents * self.exchange_rate)

    @property
    def net_eur_cents(self) -> int:
        """Computed total in EUR minus fees."""
        return self.total_eur_cents - self.cost_cents


@dataclass
class PaperlessMetadata:
    """Metadata for Paperless-ngx document upload.

    Values can be:
    - Extracted from PDF (dynamic)
    - Set statically by parser config
    - Left None for manual selection
    """

    title: str = ""
    created: str = ""  # YYYY-MM-DD
    correspondent: str | None = None  # Name (resolved to ID at upload)
    document_type: str | None = None  # Name (resolved to ID at upload)
    storage_path: str | None = None  # Name (resolved to ID at upload)
    tags: list[str] = field(default_factory=list)  # Names (resolved to IDs)
    archive_serial_number: str = ""


@dataclass
class ParseResult:
    """Combined result: transactions + Paperless metadata."""

    transactions: list[Transaction]
    metadata: PaperlessMetadata
    parser_name: str
    confidence: Confidence = Confidence.HIGH


@dataclass
class PDFContent:
    """Extracted content from a PDF."""

    text: str
    tables: list[list[list[str]]]
    page_count: int
    raw_text_by_page: list[str]


# Parser registry
_parser_registry: dict[str, type["BaseParser"]] = {}


def register_parser(cls: type["BaseParser"]) -> type["BaseParser"]:
    """Decorator to register a parser class."""
    _parser_registry[cls.name] = cls
    return cls


def get_parser_registry() -> dict[str, type["BaseParser"]]:
    """Get the parser registry."""
    return _parser_registry


class BaseParser(ABC):
    """Base class for all parsers."""

    name: str = "base"

    # Static Paperless config - set these in subclass
    # These are defaults that apply to ALL documents this parser handles
    correspondent: str | None = None  # e.g., "Scalable Capital"
    document_type: str | None = None  # e.g., "Abrechnung"
    storage_path: str | None = None
    tags: list[str] = []  # e.g., ["investments"]

    @abstractmethod
    def can_parse(self, content: PDFContent) -> tuple[bool, Confidence]:
        """Fast check if parser might handle document.

        Returns:
            tuple: (can_handle: bool, confidence: Confidence)
        """
        pass

    @abstractmethod
    def parse(self, content: PDFContent, config: dict) -> ParseResult | None:
        """Parse PDF content into transactions + metadata.

        Parser should:
        1. Extract transactions from content
        2. Build metadata (combining static config + extracted values)

        Args:
            content: Extracted PDF content
            config: Application configuration dict

        Returns:
            ParseResult if successful, None if parsing fails.
        """
        pass

    def build_metadata(self, **extracted) -> PaperlessMetadata:
        """Helper to build metadata from static config + extracted values."""
        return PaperlessMetadata(
            title=extracted.get("title", ""),
            created=extracted.get("created", ""),
            correspondent=extracted.get("correspondent", self.correspondent),
            document_type=extracted.get("document_type", self.document_type),
            storage_path=extracted.get("storage_path", self.storage_path),
            tags=list(set(self.tags + extracted.get("tags", []))),
            archive_serial_number=extracted.get("archive_serial_number", ""),
        )


def extract_pdf_content(pdf_path: str) -> PDFContent:
    """Extract all content from a PDF file using pdfplumber.

    Args:
        pdf_path: Path to the PDF file

    Returns:
        PDFContent with extracted text, tables, and page info

    Raises:
        FileNotFoundError: If PDF file doesn't exist
        ValueError: If PDF is empty or contains only images
    """
    if not Path(pdf_path).exists():
        raise FileNotFoundError(f"PDF file not found: {pdf_path}")

    text_parts = []
    raw_text_by_page = []
    all_tables = []

    with pdfplumber.open(pdf_path) as pdf:
        page_count = len(pdf.pages)

        for i, page in enumerate(pdf.pages):
            page_text = page.extract_text() or ""
            tables = page.extract_tables()

            raw_text_by_page.append(page_text)
            text_parts.append(f"--- Page {i + 1} ---")
            text_parts.append(page_text)

            # Format tables as tab-separated for LLM readability
            for table in tables:
                if table:
                    all_tables.append(table)
                    text_parts.append("\n[Table]")
                    for row in table:
                        row_text = "\t".join(str(cell) if cell else "" for cell in row)
                        text_parts.append(row_text)

    full_text = "\n".join(text_parts)
    if not full_text.strip():
        raise ValueError("PDF appears empty or contains only images")

    return PDFContent(
        text=full_text,
        tables=all_tables,
        page_count=page_count,
        raw_text_by_page=raw_text_by_page,
    )
