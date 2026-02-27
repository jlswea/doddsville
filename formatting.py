import argparse
from datetime import datetime

# ANSI escape codes
RESET = "\033[0m"
BOLD = "\033[1m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
BLUE = "\033[34m"

CURRENCY_SYMBOLS = {
    "EUR": "€",
    "USD": "$",
    "GBP": "£",
    "CHF": "CHF ",
}


def cents_from_decimal_string(value):
    """
    Custom type for argparse that converts a string with exactly two decimal
    places (e.g., '12.34') into an integer representing cents (1234).
    It bypasses float conversion to avoid precision issues.
    """
    if not isinstance(value, str):
        raise argparse.ArgumentTypeError(f"'{value}' is not a string.")

    if "." not in value:
        raise argparse.ArgumentTypeError(
            f"'{value}' must have exactly two decimal places (e.g., '12.34')."
        )

    integer_part, decimal_part = value.split(".")

    if len(decimal_part) != 2:
        raise argparse.ArgumentTypeError(
            f"'{value}' must have exactly two decimal places."
        )

    cents_string = integer_part + decimal_part

    try:
        return int(cents_string)
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"'{value}' contains non-numeric characters that prevent conversion to cents."
        )


def validate_date_format(date_string):
    """
    Custom type function for argparse to validate and parse date strings.
    Raises ValueError if the format doesn't match DD.MM.YYYY.
    """
    try:
        date_object = datetime.strptime(date_string, "%d.%m.%Y")
        return date_object
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"Invalid date format: '{date_string}'. Expected DD.MM.YYYY."
        )


def format_cents(cents, currency: str = "EUR"):
    """Format cents with currency symbol and 2 decimal places."""
    symbol = CURRENCY_SYMBOLS.get(currency, f"{currency} ")
    return f"{symbol}{(cents / 100):.2f}"


def format_cents_colored(cents):
    """Format cents with color (green positive, red negative)."""
    formatted = format_cents(abs(cents))
    if cents > 0:
        return f"{GREEN}+{formatted}{RESET}"
    elif cents < 0:
        return f"{RED}-{formatted}{RESET}"
    return formatted
