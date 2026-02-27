"""LLM-based parser using Ollama for transaction extraction."""
import json
from datetime import datetime

import requests

from .base import (
    DV_TAG,
    BaseParser,
    Confidence,
    ParseResult,
    PDFContent,
    Transaction,
    register_parser,
)


# Ollama defaults
DEFAULT_OLLAMA_URL = "http://localhost:11434"
DEFAULT_OLLAMA_MODEL = "mistral"


IMPORT_PROMPT_TEMPLATE = """You are a financial document parser. Extract all financial transactions and document metadata from the provided bank/broker statement.

Output ONLY a valid JSON object with this structure:
{{
  "transactions": [{{
    "type": "dividend",
    "date": "2025-03-17",
    "security": "Example Corp",
    "unit_price_cents": 20,
    "quantity": 62,
    "currency": "USD",
    "total_eur_cents": 1134,
    "fees": {{
      "kapitalertragsteuer": 114,
      "solidaritaetszuschlag": 7,
      "quellensteuer": 170
    }},
    "confidence": "high"
  }}],
  "metadata": {{
    "date": "2025-03-17",
    "issuer": "Scalable Capital"
  }}
}}

Transaction fields (each item in "transactions" array):

Required fields:
- "type": one of "buy", "sell", "dividend", "interest", "deposit", "withdrawal"
- "date": date in "YYYY-MM-DD" format
- "unit_price_cents": price per unit in cents of the ORIGINAL currency as positive integer (e.g., 15050 for €150.50, 20 for $0.20)
- "quantity": number of units as integer (for buy/sell: number of shares; for dividend: number of shares held; for deposit/withdrawal/interest: use 1)
- "currency": ISO currency code of unit_price_cents (e.g., "EUR", "USD"). Use the currency stated in the document for the unit price, NOT the settlement currency
- "security": security/company name (required for buy, sell, dividend)
- "total_eur_cents": gross amount in EUR cents BEFORE taxes/fees (e.g., from "Bruttobetrag EUR", "Ausmachender Betrag", "Kurswert"). Required when currency is not EUR. Do NOT use the net/Valuta amount
- "fees": object with individual tax/fee line items in EUR cents (positive integers). Extract each amount that appears with a minus sign or is labeled as a deduction. Common keys: "kapitalertragsteuer", "solidaritaetszuschlag", "quellensteuer", "kirchensteuer", "provision", "gebuehren". Only include items found in the document

Optional fields:
- "total_value_cents": gross amount in the ORIGINAL currency in cents (e.g., from "Bruttobetrag USD"). Should equal unit_price_cents * quantity
- "confidence": "high", "medium", or "low" based on parsing certainty
- "description": brief description of what this transaction is

Metadata fields:
- "date": document/statement date in YYYY-MM-DD format (the date shown on the document header)
- "issuer": name of the bank or broker that issued this document (e.g., "ING-DiBa", "Trade Republic")

Rules:
1. Convert ALL amounts to positive cents (multiply by 100, remove decimals). Example: $0.20 = 20 cents, €150.50 = 15050 cents
2. Convert German dates (DD.MM.YYYY) to YYYY-MM-DD format
3. Look for keywords: Kauf/Buy, Verkauf/Sell, Dividende/Dividend, Zinsen/Interest, Einzahlung/Deposit, Auszahlung/Withdrawal
4. unit_price_cents is the per-unit price: for dividends it is the dividend per share, for deposits/withdrawals/interest it equals the total amount with quantity=1
5. Skip header rows, totals, balance summaries, and non-transaction lines
6. If uncertain about a field, set confidence to "low"
7. IMPORTANT: Output ONLY the JSON object, no explanation, no markdown code blocks

Document text:
---
{text}
---

JSON object with transactions and metadata:"""


def call_ollama(prompt: str, config: dict) -> str:
    """Call local Ollama API to generate a response.

    Args:
        prompt: The prompt to send to Ollama
        config: Configuration dict with ollama_url and ollama_model

    Returns:
        The generated response text

    Raises:
        ConnectionError: If cannot connect to Ollama
        RuntimeError: If model not found or API error
    """
    url = config.get("ollama_url", DEFAULT_OLLAMA_URL)
    model = config.get("ollama_model", DEFAULT_OLLAMA_MODEL)

    try:
        response = requests.post(
            f"{url}/api/generate",
            json={"model": model, "prompt": prompt, "stream": False},
            timeout=120,  # 2 minutes for longer documents
        )
        response.raise_for_status()
        return response.json().get("response", "")
    except requests.exceptions.ConnectionError:
        raise ConnectionError(
            f"Cannot connect to Ollama at {url}. Start with: ollama serve"
        )
    except requests.exceptions.HTTPError as e:
        if e.response.status_code == 404:
            raise RuntimeError(f"Model '{model}' not found. Pull with: ollama pull {model}")
        raise RuntimeError(f"Ollama API error: {e}")


def parse_llm_response(response: str) -> tuple[list[dict], dict]:
    """Extract transactions and metadata from LLM response.

    Args:
        response: Raw LLM response text

    Returns:
        tuple: (transactions list, metadata dict)

    Raises:
        ValueError: If no valid JSON found in response
    """
    response = response.strip()

    # Strip markdown code blocks if present
    if response.startswith("```"):
        lines = response.split("\n")
        # Remove first line (```json or ```)
        lines = lines[1:]
        # Remove last line if it's ```
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        response = "\n".join(lines)

    # Try to find JSON object first (new format with transactions + metadata)
    obj_start = response.find("{")
    obj_end = response.rfind("}") + 1

    if obj_start != -1 and obj_end > 0:
        try:
            parsed = json.loads(response[obj_start:obj_end])
            # Check if it's the new format with transactions key
            if isinstance(parsed, dict) and "transactions" in parsed:
                transactions = parsed.get("transactions", [])
                metadata = parsed.get("metadata", {})
                return transactions, metadata
            # Single transaction object (old format fallback)
            if isinstance(parsed, dict) and "type" in parsed:
                return [parsed], {}
        except json.JSONDecodeError:
            pass

    # Try to find JSON array (old format - just transactions)
    arr_start = response.find("[")
    arr_end = response.rfind("]") + 1

    if arr_start != -1 and arr_end > 0:
        try:
            transactions = json.loads(response[arr_start:arr_end])
            return transactions, {}
        except json.JSONDecodeError:
            pass

    raise ValueError("No valid JSON found in LLM response")


def validate_parsed_transaction(txn: dict) -> tuple[bool, list[str]]:
    """Validate a parsed transaction dict has required fields.

    Args:
        txn: Transaction dict from LLM

    Returns:
        tuple: (is_valid, list of error messages)
    """
    errors = []
    valid_types = {"buy", "sell", "dividend", "interest", "deposit", "withdrawal"}

    # Check type
    txn_type = txn.get("type")
    if not txn_type:
        errors.append("missing 'type' field")
    elif txn_type not in valid_types:
        errors.append(f"invalid type '{txn_type}'")

    # Check date
    date_str = txn.get("date")
    if not date_str:
        errors.append("missing 'date' field")
    else:
        try:
            datetime.strptime(date_str, "%Y-%m-%d")
        except ValueError:
            errors.append(f"invalid date format '{date_str}' (expected YYYY-MM-DD)")

    # Check unit_price_cents (required for all transactions)
    unit_price = txn.get("unit_price_cents")
    if unit_price is None:
        errors.append("missing 'unit_price_cents' field")
    elif not isinstance(unit_price, int) or unit_price <= 0:
        errors.append(f"'unit_price_cents' must be positive integer, got {unit_price}")

    # Check quantity (required for all transactions, use 1 for deposits/withdrawals/interest)
    qty = txn.get("quantity")
    if qty is None:
        errors.append("missing 'quantity' field")
    elif not isinstance(qty, int) or qty <= 0:
        errors.append(f"'quantity' must be positive integer, got {qty}")

    # Stock transactions require security (accept "company" for backward compat)
    if txn_type in {"buy", "sell", "dividend"}:
        if not txn.get("security") and not txn.get("company"):
            errors.append(f"'{txn_type}' transaction requires 'security' field")

    return len(errors) == 0, errors


def _compute_exchange_rate(txn: dict, currency: str) -> float:
    """Compute exchange rate from EUR and original-currency totals.

    Documents typically state an EUR settlement amount (e.g., "Ausmachender
    Betrag") alongside the foreign-currency values.  Deriving the rate from
    these two numbers is more reliable than asking the LLM to invert a
    quoted rate like "EUR/USD 1.0953".
    """
    if currency == "EUR":
        return 1.0

    total_eur = txn.get("total_eur_cents")
    unit_price = txn.get("unit_price_cents", 0)
    quantity = txn.get("quantity", 1)
    total_orig = unit_price * quantity

    if isinstance(total_eur, int) and total_eur > 0 and total_orig > 0:
        return total_eur / total_orig

    # No EUR total available — fall back to LLM's exchange_rate if provided
    return txn.get("exchange_rate", 1.0)


def _sum_fees(txn: dict) -> int:
    """Sum individual fee items from the LLM's fees object.

    Falls back to cost_cents if the LLM returned a flat value instead.
    """
    fees = txn.get("fees")
    if isinstance(fees, dict):
        return sum(v for v in fees.values() if isinstance(v, (int, float)) and v > 0)
    return txn.get("cost_cents", 0)


def _confidence_from_string(conf_str: str | None) -> Confidence:
    """Convert string confidence to enum."""
    if conf_str == "high":
        return Confidence.HIGH
    elif conf_str == "medium":
        return Confidence.MEDIUM
    else:
        return Confidence.LOW


@register_parser
class LLMParser(BaseParser):
    """Parser that uses Ollama LLM to extract transactions from PDFs.

    This parser is used as a fallback when no specialized parser matches
    the document. It sends the PDF text to an LLM and parses the response.
    """

    name = "llm"

    correspondent = None
    document_type = "Abrechnung"
    storage_path = None
    tags = [DV_TAG]

    def can_parse(self, content: PDFContent) -> tuple[bool, Confidence]:
        """LLM parser can attempt to parse any document.

        Returns LOW confidence since it's a fallback parser.
        """
        # LLM can try to parse anything, but with low confidence
        # This ensures it's tried last
        return True, Confidence.LOW

    def parse(self, content: PDFContent, config: dict) -> ParseResult | None:
        """Parse PDF content using LLM.

        Args:
            content: Extracted PDF content
            config: Application configuration with ollama settings

        Returns:
            ParseResult if successful, None if parsing fails
        """
        try:
            # Generate prompt and call LLM
            prompt = IMPORT_PROMPT_TEMPLATE.format(text=content.text)
            response = call_ollama(prompt, config)

            # Parse LLM response
            raw_transactions, doc_metadata = parse_llm_response(response)

            if not raw_transactions:
                return None

            # Validate and convert transactions
            transactions = []
            for txn in raw_transactions:
                is_valid, errors = validate_parsed_transaction(txn)
                if not is_valid:
                    # Skip invalid transactions but continue
                    continue

                currency = txn.get("currency", "EUR")
                exchange_rate = _compute_exchange_rate(txn, currency)
                cost_cents = _sum_fees(txn)

                transactions.append(Transaction(
                    type=txn["type"],
                    date=txn["date"],
                    unit_price_cents=txn["unit_price_cents"],
                    quantity=txn["quantity"],
                    security=txn.get("security") or txn.get("company"),
                    cost_cents=cost_cents,
                    confidence=_confidence_from_string(txn.get("confidence")),
                    description=txn.get("description", ""),
                    currency=currency,
                    exchange_rate=exchange_rate,
                ))

            if not transactions:
                return None

            # Build metadata from LLM extraction (no static defaults)
            metadata = self.build_metadata(
                title=doc_metadata.get("title", ""),
                created=doc_metadata.get("date", ""),
                correspondent=doc_metadata.get("issuer"),  # Map issuer to correspondent
            )

            # Determine overall confidence from transactions
            confidence_counts = {Confidence.HIGH: 0, Confidence.MEDIUM: 0, Confidence.LOW: 0}
            for txn in transactions:
                confidence_counts[txn.confidence] += 1

            if confidence_counts[Confidence.LOW] > len(transactions) // 2:
                overall_confidence = Confidence.LOW
            elif confidence_counts[Confidence.HIGH] > len(transactions) // 2:
                overall_confidence = Confidence.HIGH
            else:
                overall_confidence = Confidence.MEDIUM

            return ParseResult(
                transactions=transactions,
                metadata=metadata,
                parser_name=self.name,
                confidence=overall_confidence,
            )

        except (ConnectionError, RuntimeError, ValueError, json.JSONDecodeError):
            # Let these propagate up for proper error handling in CLI
            raise
        except Exception:
            # Unexpected errors - return None to indicate failure
            return None
