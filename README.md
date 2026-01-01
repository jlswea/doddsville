# Doddsville

## Setup

### 1. Activate the Conda Environment

Before running any commands, activate the conda environment:

```bash
conda activate dv
```

### 2. Initialize the Database

```bash
sqlite3 data.db
sqlite3> .read schema.sql
```

## Usage

Parse all indices provided in `init.sql` and add their companies to the `com` table:

```bash
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

- [Conda](https://docs.conda.io/projects/conda/en/4.6.1/user-guide/tasks/manage-environments.html) - Environment management
- [SQLite CLI](https://sqlite.org/cli.html) - Database interaction
- [D2](https://d2lang.com/) - Diagram language for the schema visualization
