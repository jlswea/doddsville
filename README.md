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

Parse all indices provided in `init.sql` and add their companies to the `com` table:

```bash
pixi run python index.py
```

Or activate the environment first:

```bash
pixi shell
python index.py
```

## Database Schema

The future database layout is documented in [`docs/database_diagram.d2`](docs/database_diagram.d2). This D2 diagram shows the planned schema with the following tables:

- **accounts** - Financial accounts
- **transaction_categories** - Categories for classifying transactions
- **securities** - Stock/security information
- **counterparties** - Transaction counterparties
- **transactions** - Core transaction records linking to all other tables

## Tools

- [Pixi](https://pixi.sh) - Package and environment management
- [SQLite CLI](https://sqlite.org/cli.html) - Database interaction
- [D2](https://d2lang.com/) - Diagram language for the schema visualization
