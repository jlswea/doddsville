"""Test suite for the doddsville CLI."""
import os
import sqlite3
import tempfile
import pytest
from datetime import datetime
from unittest.mock import patch

import cli


@pytest.fixture
def temp_db():
    """Create a temporary database with the required schema."""
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)

    conn = sqlite3.connect(path)
    cur = conn.cursor()

    # Create tables
    cur.execute("""
        CREATE TABLE account (
            id INTEGER PRIMARY KEY ASC,
            name TEXT NOT NULL UNIQUE
        )
    """)

    cur.execute("""
        CREATE TABLE company (
            id INTEGER PRIMARY KEY ASC,
            isin TEXT,
            name TEXT,
            url TEXT
        )
    """)

    cur.execute("""
        CREATE TABLE "transaction" (
            id INTEGER PRIMARY KEY ASC,
            account INTEGER NOT NULL REFERENCES account (id),
            company INTEGER REFERENCES company (id),
            type TEXT CHECK (type IN (
                'buy', 'sell', 'dividend', 'interest',
                'deposit', 'withdrawal', 'transfer'
            )),
            total_value INTEGER,
            unit_value INTEGER,
            quantity INTEGER,
            cost INTEGER,
            date DATE NOT NULL,
            linked_transaction INTEGER REFERENCES "transaction" (id),
            FOREIGN KEY (company) REFERENCES company (id) ON DELETE CASCADE
        )
    """)

    # Add test data
    cur.execute("INSERT INTO account (name) VALUES (?)", ("Test Broker",))
    cur.execute("INSERT INTO account (name) VALUES (?)", ("Cash Account",))
    cur.execute("INSERT INTO company (isin, name) VALUES (?, ?)", ("US0378331005", "Apple Inc."))
    cur.execute("INSERT INTO company (isin, name) VALUES (?, ?)", ("DE0007164600", "SAP SE"))

    conn.commit()
    conn.close()

    yield path

    os.unlink(path)


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


class TestAccountCommands:
    """Tests for account commands."""

    def test_account_add(self, temp_db):
        """Test adding an account."""
        with patch.object(sqlite3, 'connect', return_value=sqlite3.connect(temp_db)):
            conn = sqlite3.connect(temp_db)
            cur = conn.cursor()

            # Before: 2 accounts (Test Broker, Cash Account)
            cur.execute("SELECT COUNT(*) FROM account")
            assert cur.fetchone()[0] == 2

            # Add new account
            cur.execute("INSERT INTO account (name) VALUES (?)", ("New Account",))
            conn.commit()

            # After: 3 accounts
            cur.execute("SELECT COUNT(*) FROM account")
            assert cur.fetchone()[0] == 3

            conn.close()

    def test_account_duplicate_fails(self, temp_db):
        """Test that duplicate account names fail."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()

        with pytest.raises(sqlite3.IntegrityError):
            cur.execute("INSERT INTO account (name) VALUES (?)", ("Test Broker",))

        conn.close()

    def test_account_list(self, temp_db):
        """Test listing accounts."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()

        cur.execute("SELECT id, name FROM account ORDER BY name")
        accounts = cur.fetchall()

        assert len(accounts) == 2
        assert accounts[0][1] == "Cash Account"
        assert accounts[1][1] == "Test Broker"

        conn.close()


class TestTransactionTypes:
    """Tests for different transaction types."""

    def test_buy_transaction(self, temp_db):
        """Test recording a buy transaction."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        cur.execute("""
            INSERT INTO "transaction"
            (account, company, type, quantity, unit_value, total_value, cost, date)
            VALUES (1, 1, 'buy', 10, 15000, 150000, 100, '2024-06-15')
        """)
        conn.commit()

        cur.execute('SELECT * FROM "transaction" WHERE type = "buy"')
        row = cur.fetchone()

        assert row is not None
        assert row[1] == 1  # account
        assert row[2] == 1  # company
        assert row[3] == "buy"  # type
        assert row[4] == 150000  # total_value
        assert row[5] == 15000  # unit_value
        assert row[6] == 10  # quantity
        assert row[7] == 100  # cost

        conn.close()

    def test_sell_transaction(self, temp_db):
        """Test recording a sell transaction."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        cur.execute("""
            INSERT INTO "transaction"
            (account, company, type, quantity, unit_value, total_value, cost, date)
            VALUES (1, 1, 'sell', 5, 16000, 80000, 50, '2024-07-15')
        """)
        conn.commit()

        cur.execute('SELECT type, quantity, total_value FROM "transaction" WHERE type = "sell"')
        row = cur.fetchone()

        assert row[0] == "sell"
        assert row[1] == 5
        assert row[2] == 80000

        conn.close()

    def test_dividend_transaction(self, temp_db):
        """Test recording a dividend transaction."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        cur.execute("""
            INSERT INTO "transaction"
            (account, company, type, total_value, cost, date)
            VALUES (1, 1, 'dividend', 5000, 0, '2024-06-01')
        """)
        conn.commit()

        cur.execute('SELECT type, total_value FROM "transaction" WHERE type = "dividend"')
        row = cur.fetchone()

        assert row[0] == "dividend"
        assert row[1] == 5000

        conn.close()

    def test_interest_transaction(self, temp_db):
        """Test recording an interest transaction."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        cur.execute("""
            INSERT INTO "transaction"
            (account, type, total_value, cost, date)
            VALUES (2, 'interest', 1000, 0, '2024-06-30')
        """)
        conn.commit()

        cur.execute('SELECT type, company FROM "transaction" WHERE type = "interest"')
        row = cur.fetchone()

        assert row[0] == "interest"
        assert row[1] is None  # No company for interest

        conn.close()

    def test_deposit_transaction(self, temp_db):
        """Test recording a deposit transaction."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        cur.execute("""
            INSERT INTO "transaction"
            (account, type, total_value, cost, date)
            VALUES (1, 'deposit', 100000, 0, '2024-01-01')
        """)
        conn.commit()

        cur.execute('SELECT type, total_value FROM "transaction" WHERE type = "deposit"')
        row = cur.fetchone()

        assert row[0] == "deposit"
        assert row[1] == 100000  # €1000.00

        conn.close()

    def test_withdrawal_transaction(self, temp_db):
        """Test recording a withdrawal transaction."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        cur.execute("""
            INSERT INTO "transaction"
            (account, type, total_value, cost, date)
            VALUES (1, 'withdrawal', 50000, 0, '2024-06-01')
        """)
        conn.commit()

        cur.execute('SELECT type, total_value FROM "transaction" WHERE type = "withdrawal"')
        row = cur.fetchone()

        assert row[0] == "withdrawal"
        assert row[1] == 50000  # €500.00

        conn.close()

    def test_transfer_transaction_pair(self, temp_db):
        """Test recording a transfer creates two linked transactions."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        # Insert outgoing transfer
        cur.execute("""
            INSERT INTO "transaction"
            (account, type, total_value, cost, date)
            VALUES (1, 'transfer', -50000, 100, '2024-06-15')
        """)
        outgoing_id = cur.lastrowid

        # Insert incoming transfer
        cur.execute("""
            INSERT INTO "transaction"
            (account, type, total_value, cost, date, linked_transaction)
            VALUES (2, 'transfer', 50000, 0, '2024-06-15', ?)
        """, (outgoing_id,))
        incoming_id = cur.lastrowid

        # Link outgoing to incoming
        cur.execute("""
            UPDATE "transaction" SET linked_transaction = ? WHERE id = ?
        """, (incoming_id, outgoing_id))

        conn.commit()

        # Verify both transactions exist and are linked
        cur.execute('SELECT id, account, total_value, linked_transaction FROM "transaction" WHERE type = "transfer" ORDER BY id')
        rows = cur.fetchall()

        assert len(rows) == 2

        # Outgoing
        assert rows[0][1] == 1  # account 1
        assert rows[0][2] == -50000  # negative value
        assert rows[0][3] == incoming_id  # linked to incoming

        # Incoming
        assert rows[1][1] == 2  # account 2
        assert rows[1][2] == 50000  # positive value
        assert rows[1][3] == outgoing_id  # linked to outgoing

        conn.close()


class TestTransactionConstraints:
    """Tests for transaction constraints and validation."""

    def test_invalid_transaction_type_fails(self, temp_db):
        """Test that invalid transaction types are rejected."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        with pytest.raises(sqlite3.IntegrityError):
            cur.execute("""
                INSERT INTO "transaction"
                (account, type, total_value, date)
                VALUES (1, 'invalid_type', 1000, '2024-06-15')
            """)

        conn.close()

    def test_missing_account_fails(self, temp_db):
        """Test that transactions require an account."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        with pytest.raises(sqlite3.IntegrityError):
            cur.execute("""
                INSERT INTO "transaction"
                (type, total_value, date)
                VALUES ('deposit', 1000, '2024-06-15')
            """)

        conn.close()

    def test_missing_date_fails(self, temp_db):
        """Test that transactions require a date."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        with pytest.raises(sqlite3.IntegrityError):
            cur.execute("""
                INSERT INTO "transaction"
                (account, type, total_value)
                VALUES (1, 'deposit', 1000)
            """)

        conn.close()

    def test_foreign_key_constraint_account(self, temp_db):
        """Test that invalid account references fail."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        with pytest.raises(sqlite3.IntegrityError):
            cur.execute("""
                INSERT INTO "transaction"
                (account, type, total_value, date)
                VALUES (999, 'deposit', 1000, '2024-06-15')
            """)

        conn.close()

    def test_foreign_key_constraint_company(self, temp_db):
        """Test that invalid company references fail."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()
        cur.execute("PRAGMA foreign_keys = ON;")

        with pytest.raises(sqlite3.IntegrityError):
            cur.execute("""
                INSERT INTO "transaction"
                (account, company, type, total_value, date)
                VALUES (1, 999, 'buy', 1000, '2024-06-15')
            """)

        conn.close()


class TestHelperFunctions:
    """Tests for helper functions."""

    def test_get_or_prompt_company_exact_match(self, temp_db):
        """Test company lookup with exact match."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()

        result = cli.get_or_prompt_company(cur, "Apple")

        assert result is not None
        assert result[2] == "Apple Inc."

        conn.close()

    def test_get_or_prompt_company_no_match(self, temp_db, capsys):
        """Test company lookup with no match."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()

        result = cli.get_or_prompt_company(cur, "NonExistentCompany")

        assert result is None
        captured = capsys.readouterr()
        assert "No company found" in captured.out

        conn.close()

    def test_get_or_prompt_account_single_match(self, temp_db):
        """Test account lookup with single match."""
        conn = sqlite3.connect(temp_db)
        cur = conn.cursor()

        result = cli.get_or_prompt_account(cur, "Test Broker")

        assert result is not None
        assert result[1] == "Test Broker"

        conn.close()

    def test_get_or_prompt_account_no_accounts(self, capsys):
        """Test account lookup when no accounts exist."""
        fd, path = tempfile.mkstemp(suffix=".db")
        os.close(fd)

        conn = sqlite3.connect(path)
        cur = conn.cursor()
        cur.execute("CREATE TABLE account (id INTEGER PRIMARY KEY, name TEXT)")
        conn.commit()

        result = cli.get_or_prompt_account(cur)

        assert result is None
        captured = capsys.readouterr()
        assert "No accounts found" in captured.out

        conn.close()
        os.unlink(path)


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


@pytest.fixture
def temp_db_with_transactions():
    """Create a temporary database with transactions for report testing."""
    fd, path = tempfile.mkstemp(suffix=".db")
    os.close(fd)

    conn = sqlite3.connect(path)
    cur = conn.cursor()

    # Create tables
    cur.execute("""
        CREATE TABLE account (
            id INTEGER PRIMARY KEY ASC,
            name TEXT NOT NULL UNIQUE
        )
    """)
    cur.execute("""
        CREATE TABLE company (
            id INTEGER PRIMARY KEY ASC,
            isin TEXT,
            name TEXT,
            url TEXT
        )
    """)
    cur.execute("""
        CREATE TABLE "transaction" (
            id INTEGER PRIMARY KEY ASC,
            account INTEGER NOT NULL REFERENCES account (id),
            company INTEGER REFERENCES company (id),
            type TEXT CHECK (type IN (
                'buy', 'sell', 'dividend', 'interest',
                'deposit', 'withdrawal', 'transfer'
            )),
            total_value INTEGER,
            unit_value INTEGER,
            quantity INTEGER,
            cost INTEGER,
            date DATE NOT NULL,
            linked_transaction INTEGER REFERENCES "transaction" (id),
            FOREIGN KEY (company) REFERENCES company (id) ON DELETE CASCADE
        )
    """)

    # Add accounts
    cur.execute("INSERT INTO account (name) VALUES (?)", ("Broker A",))
    cur.execute("INSERT INTO account (name) VALUES (?)", ("Cash",))

    # Add companies
    cur.execute("INSERT INTO company (isin, name) VALUES (?, ?)", ("US0378331005", "Apple Inc."))
    cur.execute("INSERT INTO company (isin, name) VALUES (?, ?)", ("DE0007164600", "SAP SE"))

    # Add transactions
    # Deposit €1000 to Broker A
    cur.execute("""
        INSERT INTO "transaction" (account, type, total_value, cost, date)
        VALUES (1, 'deposit', 100000, 0, '2024-01-01')
    """)
    # Buy 10 Apple shares at €100 each
    cur.execute("""
        INSERT INTO "transaction" (account, company, type, quantity, unit_value, total_value, cost, date)
        VALUES (1, 1, 'buy', 10, 10000, 100000, 500, '2024-01-15')
    """)
    # Sell 5 Apple shares at €120 each
    cur.execute("""
        INSERT INTO "transaction" (account, company, type, quantity, unit_value, total_value, cost, date)
        VALUES (1, 1, 'sell', 5, 12000, 60000, 500, '2024-06-15')
    """)
    # Dividend from Apple €25
    cur.execute("""
        INSERT INTO "transaction" (account, company, type, total_value, cost, date)
        VALUES (1, 1, 'dividend', 2500, 0, '2024-03-15')
    """)
    # Interest €10 on Cash account
    cur.execute("""
        INSERT INTO "transaction" (account, type, total_value, cost, date)
        VALUES (2, 'interest', 1000, 0, '2024-06-30')
    """)

    conn.commit()
    conn.close()

    yield path

    os.unlink(path)


class TestReportCalculations:
    """Tests for report calculation logic."""

    def test_balance_calculation(self, temp_db_with_transactions):
        """Test that balance is calculated correctly."""
        conn = sqlite3.connect(temp_db_with_transactions)
        cur = conn.cursor()

        # Calculate expected balance for Broker A:
        # +100000 (deposit) - 100000 (buy) + 60000 (sell) + 2500 (dividend) - 500 (buy fee) - 500 (sell fee)
        # = 61500 cents = €615.00
        cur.execute("""
            SELECT
                COALESCE(SUM(CASE
                    WHEN type = 'deposit' THEN total_value
                    WHEN type = 'withdrawal' THEN -total_value
                    WHEN type = 'interest' THEN total_value
                    WHEN type = 'dividend' THEN total_value
                    WHEN type = 'buy' THEN -total_value
                    WHEN type = 'sell' THEN total_value
                    WHEN type = 'transfer' THEN total_value
                    ELSE 0
                END), 0) as cash_balance,
                COALESCE(SUM(CASE WHEN cost IS NOT NULL THEN -cost ELSE 0 END), 0) as total_fees
            FROM "transaction"
            WHERE account = 1
        """)
        cash_balance, fees = cur.fetchone()

        assert cash_balance == 62500  # Before fees
        assert fees == -1000  # Total fees
        assert cash_balance + fees == 61500  # Net balance

        conn.close()

    def test_holdings_calculation(self, temp_db_with_transactions):
        """Test that holdings are calculated correctly."""
        conn = sqlite3.connect(temp_db_with_transactions)
        cur = conn.cursor()

        # Apple: bought 10, sold 5, remaining 5 shares
        cur.execute("""
            SELECT
                SUM(CASE WHEN type = 'buy' THEN quantity ELSE 0 END) as bought,
                SUM(CASE WHEN type = 'sell' THEN quantity ELSE 0 END) as sold
            FROM "transaction"
            WHERE company = 1 AND type IN ('buy', 'sell')
        """)
        bought, sold = cur.fetchone()

        assert bought == 10
        assert sold == 5
        assert bought - sold == 5  # 5 shares remaining

        conn.close()

    def test_realized_gain_calculation(self, temp_db_with_transactions):
        """Test realized gains calculation using average cost method."""
        conn = sqlite3.connect(temp_db_with_transactions)
        cur = conn.cursor()

        cur.execute("""
            SELECT
                SUM(CASE WHEN type = 'buy' THEN quantity ELSE 0 END) as bought,
                SUM(CASE WHEN type = 'sell' THEN quantity ELSE 0 END) as sold,
                SUM(CASE WHEN type = 'buy' THEN total_value ELSE 0 END) as buy_value,
                SUM(CASE WHEN type = 'sell' THEN total_value ELSE 0 END) as sell_value
            FROM "transaction"
            WHERE company = 1 AND type IN ('buy', 'sell')
        """)
        bought, sold, buy_value, sell_value = cur.fetchone()

        # Average cost per share: 100000 / 10 = 10000 cents = €100
        avg_cost = buy_value // bought
        assert avg_cost == 10000

        # Cost basis for 5 sold shares: 5 * 10000 = 50000
        cost_basis = avg_cost * sold
        assert cost_basis == 50000

        # Realized gain: 60000 (sell proceeds) - 50000 (cost basis) = 10000 cents = €100
        realized_gain = sell_value - cost_basis
        assert realized_gain == 10000

        conn.close()

    def test_cashflow_totals(self, temp_db_with_transactions):
        """Test cash flow totals calculation."""
        conn = sqlite3.connect(temp_db_with_transactions)
        cur = conn.cursor()

        cur.execute("""
            SELECT
                COALESCE(SUM(CASE WHEN type = 'deposit' THEN total_value ELSE 0 END), 0) as deposits,
                COALESCE(SUM(CASE WHEN type = 'withdrawal' THEN total_value ELSE 0 END), 0) as withdrawals,
                COALESCE(SUM(CASE WHEN type = 'dividend' THEN total_value ELSE 0 END), 0) as dividends,
                COALESCE(SUM(CASE WHEN type = 'interest' THEN total_value ELSE 0 END), 0) as interest
            FROM "transaction"
        """)
        deposits, withdrawals, dividends, interest = cur.fetchone()

        assert deposits == 100000  # €1000
        assert withdrawals == 0
        assert dividends == 2500  # €25
        assert interest == 1000  # €10

        conn.close()

    def test_date_filtering(self, temp_db_with_transactions):
        """Test that date filtering works correctly."""
        conn = sqlite3.connect(temp_db_with_transactions)
        cur = conn.cursor()

        # Only transactions before 2024-02-01
        cur.execute("""
            SELECT COUNT(*) FROM "transaction"
            WHERE date < '2024-02-01'
        """)
        count_before_feb = cur.fetchone()[0]
        assert count_before_feb == 2  # deposit and buy

        # Only transactions after 2024-06-01
        cur.execute("""
            SELECT COUNT(*) FROM "transaction"
            WHERE date > '2024-06-01'
        """)
        count_after_june = cur.fetchone()[0]
        assert count_after_june == 2  # sell and interest

        conn.close()


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
