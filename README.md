# Doddsville

## Setup

### 1. Install Dependencies

```bash
pixi install
```

### 2. Initialize the Database

```bash
sqlite3 data.db
sqlite3> .read schema.sql
```

## Usage

### CLI Commands

**Account Management:**

```bash
pixi run python cli.py account add "Broker Name"   # Create account
pixi run python cli.py account list                # List accounts
```

**Record Transactions:**

```bash
# Stock transactions
pixi run python cli.py add buy "Apple" 10 150.00 -a "Broker"
pixi run python cli.py add sell "Apple" 5 160.00 -a "Broker"
pixi run python cli.py add dividend "Apple" 25.00 -a "Broker"

# Cash transactions
pixi run python cli.py add deposit 1000.00 -a "Broker"
pixi run python cli.py add withdrawal 500.00 -a "Broker"
pixi run python cli.py add interest 10.00 -a "Cash"

# Transfer between accounts
pixi run python cli.py add transfer 500.00 --from "Cash" --to "Broker"
```

**List Transactions:**

```bash
pixi run python cli.py list                    # All transactions
pixi run python cli.py list -a "Broker"        # Filter by account
pixi run python cli.py list -t buy             # Filter by type
```

### Index Parsing

Parse all indices provided in `init.sql` and add their companies to the `company` table:

```bash
pixi run python index.py
```

### Database Migration

If upgrading from an older schema:

```bash
pixi run python migrate.py
```

### Running Tests

```bash
pixi run pytest test_cli.py -v
```

## Database Schema

![Database Schema](docs/database_diagram.svg)

The schema contains the following tables:

- **account** - Financial accounts (brokers, cash accounts)
- **company** - Stock/security information (ISIN, name)
- **transaction** - All transaction records with types: buy, sell, dividend, interest, deposit, withdrawal, transfer
- **index** - Stock market indices
- **raw_html** - Cached HTML data for scraping

## Tools

- [Pixi](https://pixi.sh) - Package and environment management
- [SQLite CLI](https://sqlite.org/cli.html) - Database interaction
- [D2](https://d2lang.com/) - Diagram language for the schema visualization
