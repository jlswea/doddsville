"""Parser for Scalable Capital documents."""

import re
from datetime import datetime

from .base import (
    BaseParser,
    Confidence,
    ParseResult,
    PDFContent,
    Transaction,
    register_parser,
    DV_TAG,
)


@register_parser
class ScalableParser(BaseParser):
    """Parser for Scalable Capital Dividendenabrechnungen (dividend statements)."""

    name = "scalable"

    # Static Paperless config
    correspondent = "Scalable"
    document_type = "Abrechnung"
    storage_path = None
    tags = [DV_TAG]

    def can_parse(self, content: PDFContent) -> tuple[bool, Confidence]:
        """Check if this is a Scalable Capital 'Dividendenabrechnung'."""
        text_lower = content.text.lower()

        if "scalable capital" and "dividendenabrechnung" in text_lower:
            return True, Confidence.HIGH

        return False, Confidence.LOW

    def parse(self, content: PDFContent, config: dict) -> ParseResult | None:
        """Parse Scalable Capital document into transactions."""
        text = content.text

        transactions = []

        txn = self._parse_dividend(text)
        if txn:
            transactions.append(txn)

        if not transactions:
            return None

        # Extract metadata
        title = self._extract_title(text)
        created = self._extract_date(text)

        # Build metadata (combines static config with extracted values)
        metadata = self.build_metadata(
            title=title,
            created=created,
        )

        return ParseResult(
            transactions=transactions,
            metadata=metadata,
            parser_name=self.name,
            confidence=Confidence.HIGH,
        )

    def _parse_dividend(self, text: str) -> Transaction | None:
        """Parse a dividend statement."""
        # Extract company name
        company = self._extract_company_name(text)
        print(f"Scalable company {company}")

        # Extract dividend amount - look for "Ausmachender Betrag" or similar
        total_value_cents = self._extract_dividend_amount(text)
        print(f"Scalable total {total_value_cents}")

        # Extract date
        date_str = self._extract_transaction_date(text)
        print(f"Scalable data {date_str}")

        # Extract withholding tax as cost
        cost_cents = self._extract_withholding_tax(text)
        print(f"Scalable fees {cost_cents}")

        if not all([company, total_value_cents, date_str]):
            return None

        # Use total as unit_price with quantity=1 when per-share breakdown not available
        return Transaction(
            type="dividend",
            date=date_str,
            unit_price_cents=total_value_cents,
            quantity=1,
            security=company,
            cost_cents=cost_cents,
            confidence=Confidence.HIGH,
            description="Scalable Capital dividend",
        )

    def _extract_company_name(self, text: str) -> str | None:
        """Extract company name from document."""
        # Look for patterns like "Name ISIN" or company name before ISIN
        # Common pattern: company name followed by ISIN on next line
        isin_pattern = r"([A-Z]{2}[A-Z0-9]{10})"
        isin_match = re.search(isin_pattern, text)

        if isin_match:
            # Get text before ISIN, look for company name
            before_isin = text[: isin_match.start()]
            lines = before_isin.strip().split("\n")

            # Company name is usually on the line before ISIN or a few lines before
            for line in reversed(lines[-5:]):
                line = line.strip()
                # Skip empty lines and common non-company text
                if not line or len(line) < 3:
                    continue
                if any(
                    skip in line.lower()
                    for skip in [
                        "wertpapierabrechnung",
                        "kauf",
                        "verkauf",
                        "stück",
                        "depotnummer",
                        "seite",
                        "datum",
                        "valuta",
                    ]
                ):
                    continue
                # This is likely the company name
                return line

        return None

    def _extract_quantity(self, text: str) -> int | None:
        """Extract quantity from document."""
        # Look for "Stück" pattern
        patterns = [
            r"(\d+(?:[.,]\d+)?)\s*Stück",
            r"Stück\s*(\d+(?:[.,]\d+)?)",
            r"Anzahl[:\s]*(\d+(?:[.,]\d+)?)",
        ]

        for pattern in patterns:
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                qty_str = match.group(1).replace(",", ".").replace(".", "")
                try:
                    return int(float(match.group(1).replace(",", ".")))
                except ValueError:
                    continue

        return None

    def _extract_unit_price(self, text: str) -> int | None:
        """Extract unit price (Kurs) in cents."""
        patterns = [
            r"Kurs[:\s]*(\d+(?:[.,]\d+)?)\s*(?:EUR|€)",
            r"Ausführungskurs[:\s]*(\d+(?:[.,]\d+)?)\s*(?:EUR|€)",
            r"(\d+(?:[.,]\d+)?)\s*(?:EUR|€)\s*/\s*Stück",
        ]

        for pattern in patterns:
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                return self._parse_german_amount(match.group(1))

        return None

    def _extract_total_value(self, text: str) -> int | None:
        """Extract total value (Kurswert or Ausmachender Betrag) in cents."""
        patterns = [
            r"Kurswert[:\s]*(\d+(?:[.,]\d+)?)\s*(?:EUR|€)",
            r"Ausmachender Betrag[:\s]*(\d+(?:[.,]\d+)?)\s*(?:EUR|€)?",
            r"Abrechnungsbetrag[:\s]*(\d+(?:[.,]\d+)?)\s*(?:EUR|€)?",
        ]

        for pattern in patterns:
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                return self._parse_german_amount(match.group(1))

        return None

    def _extract_dividend_amount(self, text: str) -> int | None:
        """Extract dividend amount in cents."""
        patterns = [
            r"Ausmachender Betrag[:\s]*(\d+(?:[.,]\d+)?)\s*(?:EUR|€)?",
            r"Nettobetrag[:\s]*(\d+(?:[.,]\d+)?)\s*(?:EUR|€)?",
            r"Dividende[:\s]*(\d+(?:[.,]\d+)?)\s*(?:EUR|€)?",
        ]

        for pattern in patterns:
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                return self._parse_german_amount(match.group(1))

        return None

    def _extract_costs(self, text: str) -> int:
        """Extract transaction costs/fees in cents."""
        patterns = [
            r"Provision[:\s]*(\d+(?:[.,]\d+)?)\s*(?:EUR|€)?",
            r"Gebühren[:\s]*(\d+(?:[.,]\d+)?)\s*(?:EUR|€)?",
            r"Ordergebühr[:\s]*(\d+(?:[.,]\d+)?)\s*(?:EUR|€)?",
        ]

        total_costs = 0
        for pattern in patterns:
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                cost = self._parse_german_amount(match.group(1))
                if cost:
                    total_costs += cost

        return total_costs

    def _extract_withholding_tax(self, text: str) -> int:
        """Extract withholding tax as cost in cents."""
        patterns = [
            r"Kapitalertragsteuer[:\s]*[-]?(\d+(?:[.,]\d+)?)\s*(?:EUR|€)?",
            r"Quellensteuer[:\s]*[-]?(\d+(?:[.,]\d+)?)\s*(?:EUR|€)?",
            r"Solidaritätszuschlag[:\s]*[-]?(\d+(?:[.,]\d+)?)\s*(?:EUR|€)?",
        ]

        total_tax = 0
        for pattern in patterns:
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                tax = self._parse_german_amount(match.group(1))
                if tax:
                    total_tax += tax

        return total_tax

    def _extract_transaction_date(self, text: str) -> str | None:
        """Extract transaction date in YYYY-MM-DD format."""
        # Look for various date patterns
        patterns = [
            r"Valuta[:\s]*(\d{2})\.(\d{2})\.(\d{4})",
            r"Schlusstag[:\s]*(\d{2})\.(\d{2})\.(\d{4})",
            r"Ausführungstag[:\s]*(\d{2})\.(\d{2})\.(\d{4})",
            r"Datum[:\s]*(\d{2})\.(\d{2})\.(\d{4})",
            r"(\d{2})\.(\d{2})\.(\d{4})",  # Generic German date
        ]

        for pattern in patterns:
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                day, month, year = match.groups()
                try:
                    date_obj = datetime(int(year), int(month), int(day))
                    return date_obj.strftime("%Y-%m-%d")
                except ValueError:
                    continue

        return None

    def _extract_title(self, text: str) -> str:
        """Generate a descriptive title for the document."""
        company = self._extract_company_name(text) or "Unknown"

        return f"Dividendenabrechnung {company}"

    def _extract_date(self, text: str) -> str:
        """Extract document date for metadata."""
        return self._extract_transaction_date(text) or ""

    def _parse_german_amount(self, amount_str: str) -> int | None:
        """Parse German number format (1.234,56) to cents."""
        if not amount_str:
            return None

        try:
            # Remove thousand separators and convert decimal comma
            clean = amount_str.replace(".", "").replace(",", ".")
            euros = float(clean)
            return int(euros * 100)
        except ValueError:
            return None
