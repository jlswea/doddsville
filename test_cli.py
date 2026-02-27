"""Test suite for the doddsville CLI."""
import os
import sqlite3
import subprocess
import tempfile
from pathlib import Path

import pytest
from datetime import datetime

import cli
from parsers.llm import parse_llm_response, validate_parsed_transaction


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
    cur.execute("INSERT INTO security (isin, name) VALUES (?, ?)", ("US0378331005", "Apple Inc."))
    cur.execute("INSERT INTO security (isin, name) VALUES (?, ?)", ("DE0007164600", "SAP SE"))

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
    cmd = ["pixi", "run", "python", "cli.py", "--db", db_path] + list(args)
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

    def test_get_or_prompt_security_exact_match(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        result = cli.get_or_prompt_security(cur, "Apple")
        assert result is not None
        assert result[2] == "Apple Inc."
        conn.close()

    def test_get_or_prompt_security_no_match(self, temp_db, capsys):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        result = cli.get_or_prompt_security(cur, "NonExistentCompany")
        assert result is None
        captured = capsys.readouterr()
        assert "No security found" in captured.out
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

    def test_foreign_key_security(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")
        with pytest.raises(sqlite3.IntegrityError):
            cur.execute("""
                INSERT INTO "transaction" (account, security, type, total_value, date)
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
    cur.execute("INSERT INTO security (isin, name) VALUES (?, ?)", ("US0378331005", "Apple Inc."))
    cur.execute("INSERT INTO security (isin, name) VALUES (?, ?)", ("US5949181045", "Microsoft Corp."))
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

    def test_config_check(self, temp_db):
        stdout, _, code = run_dv(temp_db, "config", "check")
        assert code == 0
        assert "Checking paperless-ngx connection" in stdout
        assert "paperless_url" in stdout


# =============================================================================
#                      DOCUMENT LINKING TESTS
# =============================================================================


class TestTransactionDocumentSchema:
    """Test transaction_document table schema and constraints."""

    def test_transaction_document_table_exists(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("""
            SELECT name FROM sqlite_master
            WHERE type='table' AND name='transaction_document'
        """)
        result = cur.fetchone()
        assert result is not None
        conn.close()

    def test_insert_transaction_document(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        # Add a transaction first
        cur.execute("""
            INSERT INTO "transaction" (account, type, total_value, date)
            VALUES (1, 'deposit', 10000, '2024-01-01')
        """)
        transaction_id = cur.lastrowid

        # Link a document
        cur.execute("""
            INSERT INTO transaction_document (transaction_id, paperless_id)
            VALUES (?, 123)
        """, (transaction_id,))
        conn.commit()

        # Verify
        cur.execute("SELECT paperless_id FROM transaction_document WHERE transaction_id = ?", (transaction_id,))
        result = cur.fetchone()
        assert result[0] == 123
        conn.close()

    def test_unique_constraint(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        # Add a transaction
        cur.execute("""
            INSERT INTO "transaction" (account, type, total_value, date)
            VALUES (1, 'deposit', 10000, '2024-01-01')
        """)
        transaction_id = cur.lastrowid

        # Link same document twice should fail
        cur.execute("INSERT INTO transaction_document (transaction_id, paperless_id) VALUES (?, 123)", (transaction_id,))
        with pytest.raises(sqlite3.IntegrityError):
            cur.execute("INSERT INTO transaction_document (transaction_id, paperless_id) VALUES (?, 123)", (transaction_id,))
        conn.close()

    def test_cascade_delete(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        # Add a transaction
        cur.execute("""
            INSERT INTO "transaction" (account, type, total_value, date)
            VALUES (1, 'deposit', 10000, '2024-01-01')
        """)
        transaction_id = cur.lastrowid

        # Link documents
        cur.execute("INSERT INTO transaction_document (transaction_id, paperless_id) VALUES (?, 123)", (transaction_id,))
        cur.execute("INSERT INTO transaction_document (transaction_id, paperless_id) VALUES (?, 456)", (transaction_id,))
        conn.commit()

        # Delete the transaction
        cur.execute('DELETE FROM "transaction" WHERE id = ?', (transaction_id,))
        conn.commit()

        # Document links should be deleted
        cur.execute("SELECT * FROM transaction_document WHERE transaction_id = ?", (transaction_id,))
        results = cur.fetchall()
        assert len(results) == 0
        conn.close()

    def test_multiple_documents_per_transaction(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        # Add a transaction
        cur.execute("""
            INSERT INTO "transaction" (account, type, total_value, date)
            VALUES (1, 'buy', 15000, '2024-01-15')
        """)
        transaction_id = cur.lastrowid

        # Link multiple documents
        cur.execute("INSERT INTO transaction_document (transaction_id, paperless_id) VALUES (?, 100)", (transaction_id,))
        cur.execute("INSERT INTO transaction_document (transaction_id, paperless_id) VALUES (?, 101)", (transaction_id,))
        cur.execute("INSERT INTO transaction_document (transaction_id, paperless_id) VALUES (?, 102)", (transaction_id,))
        conn.commit()

        # Verify all linked
        cur.execute("SELECT paperless_id FROM transaction_document WHERE transaction_id = ? ORDER BY paperless_id", (transaction_id,))
        results = cur.fetchall()
        assert len(results) == 3
        assert [r[0] for r in results] == [100, 101, 102]
        conn.close()


class TestInsertTransactionDocuments:
    """Test the insert_transaction_documents helper function."""

    def test_insert_single_document(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        # Add a transaction
        cur.execute("""
            INSERT INTO "transaction" (account, type, total_value, date)
            VALUES (1, 'deposit', 10000, '2024-01-01')
        """)
        transaction_id = cur.lastrowid
        conn.commit()

        # Use helper function
        cli.insert_transaction_documents(cur, transaction_id, [123])
        conn.commit()

        # Verify
        cur.execute("SELECT paperless_id FROM transaction_document WHERE transaction_id = ?", (transaction_id,))
        result = cur.fetchone()
        assert result[0] == 123
        conn.close()

    def test_insert_multiple_documents(self, temp_db):
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        # Add a transaction
        cur.execute("""
            INSERT INTO "transaction" (account, type, total_value, date)
            VALUES (1, 'buy', 15000, '2024-01-15')
        """)
        transaction_id = cur.lastrowid
        conn.commit()

        # Use helper function with multiple docs
        cli.insert_transaction_documents(cur, transaction_id, [100, 200, 300])
        conn.commit()

        # Verify all linked
        cur.execute("SELECT paperless_id FROM transaction_document WHERE transaction_id = ? ORDER BY paperless_id", (transaction_id,))
        results = cur.fetchall()
        assert len(results) == 3
        assert [r[0] for r in results] == [100, 200, 300]
        conn.close()


class TestListWithDocuments:
    """Test list command shows document information."""

    def test_list_shows_docs_column(self, temp_db):
        # Add a transaction with document
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")
        cur.execute("""
            INSERT INTO "transaction" (account, type, total_value, date)
            VALUES (1, 'deposit', 10000, '2024-01-01')
        """)
        transaction_id = cur.lastrowid
        cur.execute("INSERT INTO transaction_document (transaction_id, paperless_id) VALUES (?, 123)", (transaction_id,))
        conn.commit()
        conn.close()

        stdout, _, code = run_dv(temp_db, "list")
        assert code == 0
        assert "Docs" in stdout
        assert "123" in stdout

    def test_list_shows_multiple_docs(self, temp_db):
        # Add a transaction with multiple documents
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")
        cur.execute("""
            INSERT INTO "transaction" (account, type, total_value, date)
            VALUES (1, 'deposit', 10000, '2024-01-01')
        """)
        transaction_id = cur.lastrowid
        cur.execute("INSERT INTO transaction_document (transaction_id, paperless_id) VALUES (?, 100)", (transaction_id,))
        cur.execute("INSERT INTO transaction_document (transaction_id, paperless_id) VALUES (?, 200)", (transaction_id,))
        conn.commit()
        conn.close()

        stdout, _, code = run_dv(temp_db, "list")
        assert code == 0
        assert "100" in stdout
        assert "200" in stdout


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


# =============================================================================
#                      PDF IMPORT TESTS
# =============================================================================


class TestParseLlmResponse:
    """Tests for parse_llm_response function."""

    def test_valid_json_array(self):
        response = '[{"type": "deposit", "date": "2024-01-01", "total_value_cents": 100000}]'
        transactions, metadata = parse_llm_response(response)
        assert len(transactions) == 1
        assert transactions[0]["type"] == "deposit"
        assert transactions[0]["total_value_cents"] == 100000
        assert metadata == {}

    def test_json_with_markdown_code_block(self):
        response = '```json\n[{"type": "buy", "date": "2024-01-15", "total_value_cents": 50000}]\n```'
        transactions, metadata = parse_llm_response(response)
        assert len(transactions) == 1
        assert transactions[0]["type"] == "buy"

    def test_json_with_surrounding_text(self):
        response = 'Here are the transactions:\n[{"type": "deposit", "date": "2024-01-01", "total_value_cents": 10000}]\nDone!'
        transactions, metadata = parse_llm_response(response)
        assert len(transactions) == 1
        assert transactions[0]["type"] == "deposit"

    def test_single_object_converted_to_array(self):
        response = '{"type": "interest", "date": "2024-06-01", "total_value_cents": 2500}'
        transactions, metadata = parse_llm_response(response)
        assert len(transactions) == 1
        assert transactions[0]["type"] == "interest"

    def test_no_json_raises_error(self):
        response = "No transactions found in the document."
        with pytest.raises(ValueError):
            parse_llm_response(response)

    def test_new_format_with_metadata(self):
        response = '''{"transactions": [{"type": "buy", "date": "2024-01-15", "total_value_cents": 50000}],
                       "metadata": {"title": "Test Doc", "date": "2024-01-15", "issuer": "Bank"}}'''
        transactions, metadata = parse_llm_response(response)
        assert len(transactions) == 1
        assert transactions[0]["type"] == "buy"
        assert metadata["title"] == "Test Doc"
        assert metadata["issuer"] == "Bank"


class TestValidateParsedTransaction:
    """Tests for validate_parsed_transaction function."""

    def test_valid_deposit(self):
        txn = {"type": "deposit", "date": "2024-01-01", "unit_price_cents": 100000, "quantity": 1}
        is_valid, errors = validate_parsed_transaction(txn)
        assert is_valid
        assert len(errors) == 0

    def test_valid_buy(self):
        txn = {
            "type": "buy",
            "date": "2024-01-15",
            "security": "Apple Inc.",
            "quantity": 10,
            "unit_price_cents": 18550,
        }
        is_valid, errors = validate_parsed_transaction(txn)
        assert is_valid
        assert len(errors) == 0

    def test_missing_type(self):
        txn = {"date": "2024-01-01", "unit_price_cents": 100000, "quantity": 1}
        is_valid, errors = validate_parsed_transaction(txn)
        assert not is_valid
        assert any("type" in e for e in errors)

    def test_invalid_type(self):
        txn = {"type": "invalid", "date": "2024-01-01", "unit_price_cents": 100000, "quantity": 1}
        is_valid, errors = validate_parsed_transaction(txn)
        assert not is_valid
        assert any("invalid type" in e for e in errors)

    def test_missing_date(self):
        txn = {"type": "deposit", "unit_price_cents": 100000, "quantity": 1}
        is_valid, errors = validate_parsed_transaction(txn)
        assert not is_valid
        assert any("date" in e for e in errors)

    def test_invalid_date_format(self):
        txn = {"type": "deposit", "date": "01.01.2024", "unit_price_cents": 100000, "quantity": 1}
        is_valid, errors = validate_parsed_transaction(txn)
        assert not is_valid
        assert any("date format" in e for e in errors)

    def test_missing_unit_price(self):
        txn = {"type": "deposit", "date": "2024-01-01", "quantity": 1}
        is_valid, errors = validate_parsed_transaction(txn)
        assert not is_valid
        assert any("unit_price" in e for e in errors)

    def test_negative_unit_price(self):
        txn = {"type": "deposit", "date": "2024-01-01", "unit_price_cents": -100, "quantity": 1}
        is_valid, errors = validate_parsed_transaction(txn)
        assert not is_valid
        assert any("positive" in e for e in errors)

    def test_buy_requires_security(self):
        txn = {"type": "buy", "date": "2024-01-01", "unit_price_cents": 5000, "quantity": 10}
        is_valid, errors = validate_parsed_transaction(txn)
        assert not is_valid
        assert any("security" in e.lower() for e in errors)

    def test_sell_requires_quantity(self):
        txn = {"type": "sell", "date": "2024-01-01", "unit_price_cents": 5000, "security": "Apple"}
        is_valid, errors = validate_parsed_transaction(txn)
        assert not is_valid
        assert any("quantity" in e.lower() for e in errors)

    def test_dividend_requires_security(self):
        txn = {"type": "dividend", "date": "2024-03-15", "unit_price_cents": 50, "quantity": 50}
        is_valid, errors = validate_parsed_transaction(txn)
        assert not is_valid
        assert any("security" in e.lower() for e in errors)

    def test_interest_no_security_required(self):
        txn = {"type": "interest", "date": "2024-06-30", "unit_price_cents": 1000, "quantity": 1}
        is_valid, errors = validate_parsed_transaction(txn)
        assert is_valid


class TestImportCommandParser:
    """Test import command parser registration."""

    def test_import_help(self, temp_db):
        stdout, stderr, code = run_dv(temp_db, "import", "--help")
        # argparse returns 0 for --help
        assert code == 0
        output = stdout + stderr
        assert "pdf" in output.lower() or "PDF" in output
        assert "--account" in output or "-a" in output
        assert "--dry-run" in output
        assert "--no-upload" in output
        assert "--raw" in output

    def test_import_missing_file(self, temp_db):
        stdout, _, code = run_dv(temp_db, "import", "nonexistent.pdf", "-a", "Test Broker")
        assert "not found" in stdout.lower()


# =============================================================================
#                      MIGRATION TESTS
# =============================================================================


class TestMigration004:
    """Test migration 004: company -> security rename."""

    def test_migration_renames_table(self):
        """Test that migration 004 renames company to security."""
        from migrations import run_migrations

        fd, path = tempfile.mkstemp(suffix=".db")
        os.close(fd)

        conn = sqlite3.connect(path)
        # Apply only migrations 1-3 to get a v3 database
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS company (
                id INTEGER PRIMARY KEY ASC,
                isin TEXT,
                name TEXT,
                url TEXT
            );
            CREATE TABLE IF NOT EXISTS account (
                id INTEGER PRIMARY KEY ASC,
                name TEXT NOT NULL UNIQUE
            );
            CREATE TABLE IF NOT EXISTS "transaction" (
                id INTEGER PRIMARY KEY ASC,
                account INTEGER NOT NULL REFERENCES account (id),
                company INTEGER REFERENCES company (id),
                type TEXT,
                total_value INTEGER,
                date DATE NOT NULL
            );
            PRAGMA user_version = 3;
        """)
        conn.execute("INSERT INTO company (isin, name) VALUES ('TEST123', 'Test Corp')")
        conn.commit()

        # Run migrations (should apply 004)
        run_migrations(conn)

        # Verify security table exists
        cur = conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='security'")
        assert cur.fetchone() is not None

        # Verify type column exists
        cur = conn.execute("PRAGMA table_info(security)")
        columns = {row[1] for row in cur.fetchall()}
        assert "type" in columns

        # Verify data migrated
        cur = conn.execute("SELECT isin, name FROM security WHERE isin = 'TEST123'")
        row = cur.fetchone()
        assert row is not None
        assert row[1] == "Test Corp"

        # Verify transaction table has security column
        cur = conn.execute('PRAGMA table_info("transaction")')
        txn_columns = {row[1] for row in cur.fetchall()}
        assert "security" in txn_columns
        assert "company" not in txn_columns

        conn.close()
        os.unlink(path)


# =============================================================================
#                      SENSOR TESTS
# =============================================================================


class TestSensorDiscovery:
    """Test sensor plugin discovery."""

    def test_sensor_registry_populated(self):
        from sensors import list_sensors
        sensors = list_sensors()
        names = [s["name"] for s in sensors]
        assert "tagesschau" in names
        assert "justetf" in names

    def test_sensor_list_command(self, temp_db):
        stdout, _, code = run_dv(temp_db, "sensor", "list")
        assert code == 0
        assert "tagesschau" in stdout
        assert "justetf" in stdout

    def test_sensor_run_dry_run(self, temp_db):
        """Test dry run with mocked HTTP — no real network calls, no DB writes."""
        from unittest.mock import patch, MagicMock
        from sensors import run_sensor
        from sensors.base import Security, SecurityType

        conn = sqlite3.connect(temp_db)
        conn.execute("PRAGMA foreign_keys = ON")
        cur = conn.cursor()

        # Mock the scrape method to return fake data without HTTP calls
        fake_securities = [
            Security(isin="TEST00000001", name="Test ETF 1", type=SecurityType.ETF, url="https://example.com/1"),
            Security(isin="TEST00000002", name="Test ETF 2", type=SecurityType.ETF, url="https://example.com/2"),
        ]
        with patch("sensors.justetf.requests.get") as mock_get:
            mock_resp = MagicMock()
            mock_resp.status_code = 200
            mock_resp.raise_for_status = MagicMock()
            mock_resp.text = 'var id10Etfs = [{"isin":"TEST00000001","name":"Test ETF 1","url":"/etf/1"},{"isin":"TEST00000002","name":"Test ETF 2","url":"/etf/2"}];'
            mock_get.return_value = mock_resp

            result = run_sensor("justetf", {"urls": ["https://example.com"]}, cur)

        assert len(result.securities) == 2
        assert result.stats["inserted"] == 2
        assert len(result.stats["inserted_items"]) == 2
        assert result.stats["inserted_items"][0]["isin"] == "TEST00000001"

        # Verify nothing was committed (dry-run behavior)
        conn.rollback()
        cur.execute("SELECT COUNT(*) FROM security WHERE isin LIKE 'TEST%'")
        assert cur.fetchone()[0] == 0
        conn.close()

    def test_sensor_run_upsert_diff(self, temp_db):
        """Test that upsert tracks changes correctly."""
        from sensors.base import Security, SecurityType, get_sensor_registry

        conn = sqlite3.connect(temp_db)
        conn.execute("PRAGMA foreign_keys = ON")
        cur = conn.cursor()

        # Insert a security that will be updated
        cur.execute(
            "INSERT INTO security (isin, name, url, type) VALUES (?, ?, ?, ?)",
            ("DIFF00000001", "Old Name", "https://old.com", "etf"),
        )

        # Use a concrete sensor instance for upsert_securities
        sensor = get_sensor_registry()["justetf"]()
        securities = [
            Security(isin="DIFF00000001", name="New Name", type=SecurityType.ETF, url="https://new.com"),
            Security(isin="DIFF00000002", name="Brand New", type=SecurityType.ETF, url="https://brand.new"),
        ]
        stats = sensor.upsert_securities(cur, securities)

        assert stats["updated"] == 1
        assert stats["inserted"] == 1
        assert stats["unchanged"] == 0
        assert stats["updated_items"][0]["isin"] == "DIFF00000001"
        assert stats["updated_items"][0]["changes"]["name"] == ("Old Name", "New Name")
        assert stats["updated_items"][0]["changes"]["url"] == ("https://old.com", "https://new.com")
        assert stats["inserted_items"][0]["isin"] == "DIFF00000002"

        conn.rollback()
        conn.close()

    def test_sensor_run_unknown(self, temp_db):
        stdout, _, code = run_dv(temp_db, "sensor", "run", "nonexistent")
        assert code == 0
        assert "unknown" in stdout.lower() or "Unknown" in stdout


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
