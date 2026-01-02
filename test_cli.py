"""Test suite for the doddsville CLI."""
import os
import sqlite3
import subprocess
import tempfile
from pathlib import Path

import pytest
from datetime import datetime

import cli


# Path to schema.sql
SCHEMA_PATH = Path(__file__).parent / "schema.sql"


def create_db_from_schema():
    """Create a temporary database using schema.sql."""
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)

    conn = sqlite3.connect(path)
    with open(SCHEMA_PATH) as f:
        conn.executescript(f.read())
    conn.commit()
    conn.close()

    return path


@pytest.fixture
def temp_db():
    """Create a temporary database from schema.sql with sample data."""
    path = create_db_from_schema()

    conn = sqlite3.connect(path)
    cur = conn.cursor()

    # Add test data
    cur.execute("INSERT INTO account (name) VALUES (?)", ("Test Broker",))
    cur.execute("INSERT INTO account (name) VALUES (?)", ("Cash Account",))
    cur.execute("INSERT INTO company (isin, name) VALUES (?, ?)", ("US0378331005", "Apple Inc."))
    cur.execute("INSERT INTO company (isin, name) VALUES (?, ?)", ("DE0007164600", "SAP SE"))

    conn.commit()
    conn.close()

    yield path

    os.unlink(path)


@pytest.fixture
def empty_db():
    """Create an empty database from schema.sql."""
    path = create_db_from_schema()
    yield path
    os.unlink(path)


def run_dv(db_path, *args, input_text=None):
    """Run dv CLI command and return output."""
    cmd = ["pixi", "run", "dv", "--db", db_path] + list(args)
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        input=input_text,
    )
    return result.stdout, result.stderr, result.returncode


# =============================================================================
#                           UNIT TESTS
# =============================================================================


class TestCentsFromDecimalString:
    """Tests for cents_from_decimal_string function."""

    def test_valid_conversion(self):
        assert cli.cents_from_decimal_string("12.34") == 1234
        assert cli.cents_from_decimal_string("0.01") == 1
        assert cli.cents_from_decimal_string("100.00") == 10000
        assert cli.cents_from_decimal_string("1234.56") == 123456

    def test_negative_values(self):
        assert cli.cents_from_decimal_string("-12.34") == -1234

    def test_missing_decimal_point(self):
        import argparse
        with pytest.raises(argparse.ArgumentTypeError):
            cli.cents_from_decimal_string("1234")

    def test_wrong_decimal_places(self):
        import argparse
        with pytest.raises(argparse.ArgumentTypeError):
            cli.cents_from_decimal_string("12.3")
        with pytest.raises(argparse.ArgumentTypeError):
            cli.cents_from_decimal_string("12.345")


class TestValidateDateFormat:
    """Tests for validate_date_format function."""

    def test_valid_date(self):
        result = cli.validate_date_format("15.06.2024")
        assert isinstance(result, datetime)
        assert result.day == 15
        assert result.month == 6
        assert result.year == 2024

    def test_invalid_format(self):
        import argparse
        with pytest.raises(argparse.ArgumentTypeError):
            cli.validate_date_format("2024-06-15")
        with pytest.raises(argparse.ArgumentTypeError):
            cli.validate_date_format("15/06/2024")


class TestFormatCents:
    """Tests for format_cents function."""

    def test_format_cents(self):
        assert cli.format_cents(1234) == "€12.34"
        assert cli.format_cents(100) == "€1.00"
        assert cli.format_cents(1) == "€0.01"
        assert cli.format_cents(0) == "€0.00"

    def test_negative_cents(self):
        assert cli.format_cents(-1234) == "€-12.34"


class TestFormatCentsColored:
    """Tests for format_cents_colored function."""

    def test_positive_value(self):
        result = cli.format_cents_colored(1234)
        assert "+€12.34" in result
        assert cli.GREEN in result

    def test_negative_value(self):
        result = cli.format_cents_colored(-1234)
        assert "-€12.34" in result
        assert cli.RED in result

    def test_zero_value(self):
        result = cli.format_cents_colored(0)
        assert "€0.00" in result


class TestHelperFunctions:
    """Tests for helper functions."""

    def test_get_or_prompt_company_exact_match(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        result = cli.get_or_prompt_company(cur, "Apple")
        assert result is not None
        assert result[2] == "Apple Inc."
        conn.close()

    def test_get_or_prompt_company_no_match(self, temp_db, capsys):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        result = cli.get_or_prompt_company(cur, "NonExistentCompany")
        assert result is None
        captured = capsys.readouterr()
        assert "No company found" in captured.out
        conn.close()

    def test_get_or_prompt_account_single_match(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        result = cli.get_or_prompt_account(cur, "Test Broker")
        assert result is not None
        assert result[1] == "Test Broker"
        conn.close()


# =============================================================================
#                      DATABASE CONSTRAINT TESTS
# =============================================================================


class TestSchemaConstraints:
    """Tests for database schema constraints."""

    def test_account_unique_name(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        with pytest.raises(sqlite3.IntegrityError):
            cur.execute("INSERT INTO account (name) VALUES (?)", ("Test Broker",))
        conn.close()

    def test_transaction_type_check(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")
        with pytest.raises(sqlite3.IntegrityError):
            cur.execute("""
                INSERT INTO "transaction" (account, type, total_value, date)
                VALUES (1, 'invalid_type', 1000, '2024-06-15')
            """)
        conn.close()

    def test_transaction_requires_account(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")
        with pytest.raises(sqlite3.IntegrityError):
            cur.execute("""
                INSERT INTO "transaction" (type, total_value, date)
                VALUES ('deposit', 1000, '2024-06-15')
            """)
        conn.close()

    def test_transaction_requires_date(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")
        with pytest.raises(sqlite3.IntegrityError):
            cur.execute("""
                INSERT INTO "transaction" (account, type, total_value)
                VALUES (1, 'deposit', 1000)
            """)
        conn.close()

    def test_foreign_key_account(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")
        with pytest.raises(sqlite3.IntegrityError):
            cur.execute("""
                INSERT INTO "transaction" (account, type, total_value, date)
                VALUES (999, 'deposit', 1000, '2024-06-15')
            """)
        conn.close()

    def test_foreign_key_company(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")
        with pytest.raises(sqlite3.IntegrityError):
            cur.execute("""
                INSERT INTO "transaction" (account, company, type, total_value, date)
                VALUES (1, 999, 'buy', 1000, '2024-06-15')
            """)
        conn.close()


# =============================================================================
#                      CLI INTEGRATION TESTS
# =============================================================================


class TestCLIAccountCommands:
    """Test account CLI commands."""

    def test_account_add(self, empty_db):
        stdout, _, code = run_dv(empty_db, "account", "add", "New Broker")
        assert code == 0
        assert "created" in stdout.lower()

    def test_account_add_duplicate(self, empty_db):
        run_dv(empty_db, "account", "add", "Broker")
        stdout, _, code = run_dv(empty_db, "account", "add", "Broker")
        assert "already exists" in stdout.lower()

    def test_account_list(self, empty_db):
        run_dv(empty_db, "account", "add", "Broker A")
        run_dv(empty_db, "account", "add", "Broker B")
        stdout, _, code = run_dv(empty_db, "account", "list")
        assert code == 0
        assert "Broker A" in stdout
        assert "Broker B" in stdout


class TestCLITransactionCommands:
    """Test transaction CLI commands."""

    def test_deposit(self, temp_db):
        stdout, _, code = run_dv(
            temp_db, "add", "deposit", "1000.00", "-a", "Test Broker", "-d", "01.01.2024",
            input_text="y\n"
        )
        assert code == 0
        assert "recorded" in stdout.lower()

    def test_buy(self, temp_db):
        stdout, _, code = run_dv(
            temp_db, "add", "buy", "Apple", "10", "150.00", "-a", "Test Broker", "-d", "01.01.2024",
            input_text="y\n"
        )
        assert code == 0
        assert "recorded" in stdout.lower()

    def test_sell(self, temp_db):
        run_dv(temp_db, "add", "buy", "Apple", "10", "150.00", "-a", "Test Broker", "-d", "01.01.2024", input_text="y\n")
        stdout, _, code = run_dv(
            temp_db, "add", "sell", "Apple", "5", "160.00", "-a", "Test Broker", "-d", "01.06.2024",
            input_text="y\n"
        )
        assert code == 0
        assert "recorded" in stdout.lower()

    def test_dividend(self, temp_db):
        stdout, _, code = run_dv(
            temp_db, "add", "dividend", "Apple", "25.00", "-a", "Test Broker", "-d", "01.03.2024",
            input_text="y\n"
        )
        assert code == 0
        assert "recorded" in stdout.lower()

    def test_interest(self, temp_db):
        stdout, _, code = run_dv(
            temp_db, "add", "interest", "10.00", "-a", "Test Broker", "-d", "01.06.2024",
            input_text="y\n"
        )
        assert code == 0
        assert "recorded" in stdout.lower()

    def test_withdrawal(self, temp_db):
        stdout, _, code = run_dv(
            temp_db, "add", "withdrawal", "500.00", "-a", "Test Broker", "-d", "01.06.2024",
            input_text="y\n"
        )
        assert code == 0
        assert "recorded" in stdout.lower()

    def test_transfer(self, temp_db):
        stdout, _, code = run_dv(
            temp_db, "add", "transfer", "500.00", "--from", "Test Broker", "--to", "Cash Account", "-d", "01.03.2024",
            input_text="y\n"
        )
        assert code == 0
        assert "recorded" in stdout.lower()
        assert "<->" in stdout


class TestCLIListCommand:
    """Test list CLI command."""

    def test_list_empty(self, temp_db):
        stdout, _, code = run_dv(temp_db, "list")
        assert code == 0
        assert "no transactions" in stdout.lower()

    def test_list_with_transactions(self, temp_db):
        run_dv(temp_db, "add", "deposit", "1000.00", "-a", "Test Broker", "-d", "01.01.2024", input_text="y\n")
        run_dv(temp_db, "add", "buy", "Apple", "5", "100.00", "-a", "Test Broker", "-d", "15.01.2024", input_text="y\n")
        stdout, _, code = run_dv(temp_db, "list")
        assert code == 0
        assert "deposit" in stdout.lower()
        assert "buy" in stdout.lower()
        assert "Apple" in stdout

    def test_list_filter_by_type(self, temp_db):
        run_dv(temp_db, "add", "deposit", "1000.00", "-a", "Test Broker", "-d", "01.01.2024", input_text="y\n")
        run_dv(temp_db, "add", "buy", "Apple", "5", "100.00", "-a", "Test Broker", "-d", "15.01.2024", input_text="y\n")
        stdout, _, code = run_dv(temp_db, "list", "-t", "buy")
        assert code == 0
        assert "buy" in stdout.lower()
        assert "deposit" not in stdout.lower()

    def test_list_filter_by_account(self, temp_db):
        run_dv(temp_db, "add", "deposit", "1000.00", "-a", "Test Broker", "-d", "01.01.2024", input_text="y\n")
        run_dv(temp_db, "add", "deposit", "500.00", "-a", "Cash Account", "-d", "01.01.2024", input_text="y\n")
        stdout, _, code = run_dv(temp_db, "list", "-a", "Cash")
        assert code == 0
        assert "Cash Account" in stdout
        assert "Test Broker" not in stdout


# =============================================================================
#                      REPORT INTEGRATION TESTS
# =============================================================================


@pytest.fixture
def populated_db():
    """Create a database with a full set of sample transactions for report testing."""
    path = create_db_from_schema()

    # Add companies
    conn = sqlite3.connect(path)
    cur = conn.cursor()
    cur.execute("INSERT INTO company (isin, name) VALUES (?, ?)", ("US0378331005", "Apple Inc."))
    cur.execute("INSERT INTO company (isin, name) VALUES (?, ?)", ("US5949181045", "Microsoft Corp."))
    conn.commit()
    conn.close()

    # Add accounts
    run_dv(path, "account", "add", "Scalable Broker")
    run_dv(path, "account", "add", "Trade Republic")

    # Deposits
    run_dv(path, "add", "deposit", "5000.00", "-a", "Scalable", "-d", "01.01.2024", input_text="y\n")
    run_dv(path, "add", "deposit", "3000.00", "-a", "Trade", "-d", "01.01.2024", input_text="y\n")

    # Buy stocks
    run_dv(path, "add", "buy", "Apple", "20", "185.50", "-a", "Scalable", "-d", "15.01.2024", "-c", "1.00", input_text="y\n")
    run_dv(path, "add", "buy", "Microsoft", "10", "380.00", "-a", "Trade", "-d", "20.01.2024", "-c", "1.00", input_text="y\n")

    # Transfer
    run_dv(path, "add", "transfer", "500.00", "--from", "Scalable", "--to", "Trade", "-d", "01.03.2024", input_text="y\n")

    # Dividend
    run_dv(path, "add", "dividend", "Apple", "48.00", "-a", "Scalable", "-d", "15.03.2024", input_text="y\n")

    # Sell some shares
    run_dv(path, "add", "sell", "Apple", "10", "195.00", "-a", "Scalable", "-d", "15.06.2024", "-c", "1.00", input_text="y\n")

    # Interest
    run_dv(path, "add", "interest", "25.00", "-a", "Scalable", "-d", "30.06.2024", input_text="y\n")

    yield path

    os.unlink(path)


class TestReportSummary:
    """Test summary report."""

    def test_summary_report(self, populated_db):
        stdout, _, code = run_dv(populated_db, "report", "summary")
        assert code == 0
        assert "INVESTMENT SUMMARY" in stdout
        assert "Cash Flow" in stdout
        assert "Income" in stdout
        assert "Performance" in stdout
        assert "€8000.00" in stdout  # Total deposits

    def test_summary_with_date_filter(self, populated_db):
        stdout, _, code = run_dv(populated_db, "report", "summary", "--from", "01.06.2024")
        assert code == 0
        assert "€25.00" in stdout  # Interest from June


class TestReportBalance:
    """Test balance report."""

    def test_balance_report(self, populated_db):
        stdout, _, code = run_dv(populated_db, "report", "balance")
        assert code == 0
        assert "Account Balances" in stdout
        assert "Scalable Broker" in stdout
        assert "Trade Republic" in stdout
        assert "TOTAL" in stdout


class TestReportCashflow:
    """Test cashflow report."""

    def test_cashflow_report(self, populated_db):
        stdout, _, code = run_dv(populated_db, "report", "cashflow")
        assert code == 0
        assert "Cash Flow Report" in stdout
        assert "Deposits" in stdout
        assert "Dividends" in stdout
        assert "€5000.00" in stdout  # Scalable deposit
        assert "€3000.00" in stdout  # Trade deposit


class TestReportHoldings:
    """Test holdings report."""

    def test_holdings_report(self, populated_db):
        stdout, _, code = run_dv(populated_db, "report", "holdings")
        assert code == 0
        assert "Portfolio Holdings" in stdout
        assert "Apple" in stdout
        assert "Microsoft" in stdout

    def test_holdings_empty(self, temp_db):
        stdout, _, code = run_dv(temp_db, "report", "holdings")
        assert code == 0
        assert "no holdings" in stdout.lower()


class TestReportPerformance:
    """Test performance report."""

    def test_performance_report(self, populated_db):
        stdout, _, code = run_dv(populated_db, "report", "performance")
        assert code == 0
        assert "Investment Performance" in stdout
        assert "Apple" in stdout
        assert "Microsoft" in stdout
        assert "Realized" in stdout
        # Realized gain: sold 10 Apple at €195, bought at €185.50 = €95 profit
        assert "€95.00" in stdout

    def test_performance_shows_dividends(self, populated_db):
        stdout, _, code = run_dv(populated_db, "report", "performance")
        assert code == 0
        assert "€48.00" in stdout  # Apple dividend


class TestConfigCommand:
    """Test config command."""

    def test_config_show(self, temp_db):
        stdout, _, code = run_dv(temp_db, "config", "show")
        assert code == 0
        assert "Configuration" in stdout
        assert "db" in stdout


class TestDatabaseFlag:
    """Test --db flag functionality."""

    def test_db_flag_isolates_databases(self):
        path1 = create_db_from_schema()
        path2 = create_db_from_schema()

        try:
            run_dv(path1, "account", "add", "Database One Account")
            run_dv(path2, "account", "add", "Database Two Account")

            stdout1, _, _ = run_dv(path1, "account", "list")
            stdout2, _, _ = run_dv(path2, "account", "list")

            assert "Database One Account" in stdout1
            assert "Database Two Account" not in stdout1
            assert "Database Two Account" in stdout2
            assert "Database One Account" not in stdout2
        finally:
            os.unlink(path1)
            os.unlink(path2)


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
