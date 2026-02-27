"""Parser registry and orchestrator for PDF document parsing."""

import importlib
import pkgutil
from pathlib import Path

from .base import (
    BaseParser,
    Confidence,
    ParseResult,
    PDFContent,
    PaperlessMetadata,
    Transaction,
    extract_pdf_content,
    get_parser_registry,
    register_parser,
)


def discover_parsers() -> None:
    """Auto-discover and import all parser modules in the parsers package.

    This loads all .py files in the parsers directory (except __init__ and base),
    which triggers the @register_parser decorators.
    """
    package_dir = Path(__file__).parent

    for module_info in pkgutil.iter_modules([str(package_dir)]):
        if module_info.name not in ("base", "__init__"):
            importlib.import_module(f".{module_info.name}", package=__name__)


def classify_parsers(content: PDFContent) -> list[tuple[BaseParser, Confidence]]:
    """Classify content against all registered parsers.

    Args:
        content: Extracted PDF content

    Returns:
        List of (parser_instance, confidence) tuples, sorted by confidence
        (HIGH > MEDIUM > LOW)
    """
    registry = get_parser_registry()
    results = []

    for parser_cls in registry.values():
        parser = parser_cls()
        can_parse, confidence = parser.can_parse(content)
        if can_parse:
            results.append((parser, confidence))

    # Sort by confidence (HIGH first, then MEDIUM, then LOW)
    confidence_order = {Confidence.HIGH: 0, Confidence.MEDIUM: 1, Confidence.LOW: 2}
    results.sort(key=lambda x: confidence_order[x[1]])

    return results


def parse_document(
    content: PDFContent,
    config: dict,
    force_parser: str | None = None,
) -> ParseResult | None:
    """Parse a PDF document using registered parsers.

    1. If force_parser is specified, use only that parser
    2. Otherwise, classify content against all registered parsers
    3. Sort by confidence (HIGH > MEDIUM > LOW)
    4. Try each parser until one succeeds
    5. Fall back to LLM parser if all others fail

    Args:
        content: Extracted PDF content
        config: Application configuration dict
        force_parser: Optional parser name to force

    Returns:
        ParseResult if successful, None if all parsers fail
    """
    registry = get_parser_registry()

    if force_parser:
        if force_parser not in registry:
            available = ", ".join(registry.keys())
            raise ValueError(f"Unknown parser '{force_parser}'. Available: {available}")
        parser = registry[force_parser]()
        return parser.parse(content, config)

    # Classify and try parsers in order of confidence
    classified = classify_parsers(content)

    # Separate LLM parser from others (it's our fallback)
    llm_parser = None
    other_parsers = []

    for parser, confidence in classified:
        print(parser, confidence)
        if parser.name == "llm":
            llm_parser = parser
        else:
            other_parsers.append((parser, confidence))

    # Try non-LLM parsers first
    for parser, confidence in other_parsers:
        result = parser.parse(content, config)
        print(parser, result)
        if result is not None:
            return result

    # Fall back to LLM parser
    if llm_parser:
        return llm_parser.parse(content, config)

    # If no LLM parser registered, try to get it from registry
    if "llm" in registry and llm_parser is None:
        llm_parser = registry["llm"]()
        return llm_parser.parse(content, config)

    return None


def list_parsers() -> list[dict]:
    """List all available parsers with their metadata.

    Returns:
        List of dicts with parser info: name, correspondent, document_type, tags
    """
    registry = get_parser_registry()
    parsers = []

    for name, parser_cls in registry.items():
        parsers.append(
            {
                "name": name,
                "correspondent": parser_cls.correspondent,
                "document_type": parser_cls.document_type,
                "tags": parser_cls.tags,
            }
        )

    return parsers


# Auto-discover parsers on import
discover_parsers()


__all__ = [
    "BaseParser",
    "Confidence",
    "ParseResult",
    "PDFContent",
    "PaperlessMetadata",
    "Transaction",
    "extract_pdf_content",
    "register_parser",
    "parse_document",
    "list_parsers",
    "classify_parsers",
]
