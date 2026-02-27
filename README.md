# Doddsville

## Setup

### 1. Install Dependencies

```bash
pixi install
```

### 2. Install the CLI

This step is required after each `pixi install`:

```bash
pixi run install-cli
```

Or use `pixi run dv` directly (auto-installs the CLI).

### 3. Database Migrations

Database migrations run automatically on every CLI invocation using SQLite's `PRAGMA user_version`. No manual migration step is needed.

## Usage

All commands use `pixi run dv` (or just `dv` if you activate the shell with `pixi shell`).

**Account Management:**

```bash
pixi run dv account add "Broker Name"   # Create account
pixi run dv account list                # List accounts
```

**Record Transactions:**

```bash
# Stock transactions
pixi run dv add buy "Apple" 10 150.00 -a "Broker"
pixi run dv add sell "Apple" 5 160.00 -a "Broker"
pixi run dv add dividend "Apple" 25.00 -a "Broker"

# Cash transactions
pixi run dv add deposit 1000.00 -a "Broker"
pixi run dv add withdrawal 500.00 -a "Broker"
pixi run dv add interest 10.00 -a "Cash"

# Transfer between accounts
pixi run dv add transfer 500.00 --from "Cash" --to "Broker"
```

**Edit Transactions:**

```bash
# Edit an existing transaction (interactive editor)
pixi run dv edit 42
```

**List Transactions:**

```bash
pixi run dv list                    # All transactions
pixi run dv list -a "Broker"        # Filter by account
pixi run dv list -t buy             # Filter by type
```

**Reports:**

```bash
# Summary of all metrics
pixi run dv report summary

# Account balances
pixi run dv report balance

# Cash flow (deposits, withdrawals, dividends, interest)
pixi run dv report cashflow

# Current stock holdings
pixi run dv report holdings

# Investment performance (realized gains/losses)
pixi run dv report performance

# Filter by account or date range
pixi run dv report summary -a "Broker"
pixi run dv report cashflow --from 01.01.2024 --to 31.12.2024
```

## Paperless-ngx Integration

Attach documents to transactions using a paperless-ngx server.

**Setup:**

```bash
# Configure paperless connection
pixi run dv config set paperless_url http://localhost:8000
pixi run dv config set paperless_token your-api-token

# Verify connection
pixi run dv config check
```

**Attach documents to transactions:**

```bash
# Link existing document by paperless ID
pixi run dv add buy "Apple" 10 150.00 -a "Broker" --doc 123

# Upload new document (auto-uploads to paperless)
pixi run dv add buy "Apple" 10 150.00 -a "Broker" --doc ./receipt.pdf

# Multiple documents
pixi run dv add deposit 1000.00 -a "Broker" --doc 123 ./statement.pdf
```

**Add documents to existing transactions:**

```bash
# Link by paperless document ID
pixi run dv doc add 42 123

# Upload and link a file
pixi run dv doc add 42 ./receipt.pdf

# Multiple documents at once
pixi run dv doc add 42 123 456 ./statement.pdf
```

**Edit document metadata:**

```bash
# Edit metadata of a Paperless document (title, correspondent, type, etc.)
pixi run dv doc edit 123
```

If the document is linked to transactions in dv but the `dv_transaction_id` custom field is missing (e.g. due to a previous error), `doc edit` will automatically set it.

Documents are shown as clickable URLs in `dv list` output.

**Transaction ID custom field:**

When documents are linked to transactions (via `dv add --doc`, `dv doc add`, or `dv import`), a `dv_transaction_id` custom field is automatically set on the Paperless document containing the linked transaction ID(s) as a comma-separated string (e.g. `"1,2,3"`). This allows navigating from Paperless back to the corresponding `dv` transactions. The custom field is created automatically on first use. If multiple transactions reference the same document, the IDs are merged.

## PDF Import

Import transactions from bank/broker PDF statements using AI-powered parsing with a local Ollama LLM.

**Prerequisites:**

- [Ollama](https://ollama.com/) running locally
- A model installed (e.g., `ollama pull mistral`)

**Setup:**

```bash
# Configure Ollama (optional, defaults shown)
pixi run dv config set ollama_url http://localhost:11434
pixi run dv config set ollama_model mistral
```

**Import transactions:**

```bash
# Basic import
pixi run dv import statement.pdf -a "Scalable Broker"

# Preview without inserting (dry run)
pixi run dv import statement.pdf --dry-run

# Import without uploading to paperless
pixi run dv import statement.pdf -a "Broker" --no-upload

# Use a different model
pixi run dv import statement.pdf --model llama3.2

# Debug: view extracted text
pixi run dv import statement.pdf --raw
```

**How it works:**

1. Extracts text and tables from the PDF using pdfplumber
2. Sends the text to a local Ollama LLM with a structured prompt
3. LLM returns JSON array of parsed transactions
4. Validates and previews the transactions
5. On confirmation, inserts into database
6. Optionally uploads PDF to paperless and links to all created transactions

**Supported transaction types:** buy, sell, dividend, interest, deposit, withdrawal

**Note:** The LLM handles German (DD.MM.YYYY) and ISO (YYYY-MM-DD) date formats, and recognizes German keywords (Kauf, Verkauf, Dividende, Zinsen, Einzahlung, Auszahlung).

### Index Parsing

Parse all indices provided in `init.sql` and add their companies to the `company` table:

```bash
pixi run python index.py
```

### Running Tests

```bash
pixi run pytest test_cli.py -v
```

## Project Structure

```
doddsville/
├── cli.py              # Entry point: argparse setup + dispatch
├── config.py           # Config directory/file management
├── db.py               # DB helpers (get_or_prompt_account/company, holdings)
├── formatting.py       # ANSI codes, currency formatting, validators
├── migrations.py       # Schema migrations via PRAGMA user_version
├── paperless.py        # Paperless-ngx API + document helpers
├── ui.py               # Preview/edit functions for import workflow
├── commands/           # Command handler modules
│   ├── account_cmd.py  #   account add/list
│   ├── add_cmd.py      #   add buy/sell/dividend/interest/deposit/withdrawal/transfer
│   ├── config_cmd.py   #   config show/set/check
│   ├── doc_cmd.py      #   doc add/edit
│   ├── edit_cmd.py     #   edit transaction
│   ├── import_cmd.py   #   import (PDF parsing + insertion)
│   ├── list_cmd.py     #   list transactions
│   └── report_cmd.py   #   report summary/balance/cashflow/holdings/performance
├── parsers/            # PDF parsing modules
│   ├── base.py         #   Base parser interface
│   ├── llm.py          #   Ollama LLM parser
│   └── scalable*.py    #   Scalable Capital-specific parsers
├── schema.sql          # Full schema for fresh/test databases
└── test_cli.py         # Test suite
```

## Database Schema

![Database Schema](docs/database_diagram.svg)

The schema contains the following tables:

- **account** - Financial accounts (brokers, cash accounts)
- **company** - Stock/security information (ISIN, name)
- **transaction** - All transaction records with types: buy, sell, dividend, interest, deposit, withdrawal, transfer
- **transaction_document** - Links transactions to paperless-ngx documents
- **index** - Stock market indices
- **raw_html** - Cached HTML data for scraping

## Tools

- [Pixi](https://pixi.sh) - Package and environment management
- [SQLite CLI](https://sqlite.org/cli.html) - Database interaction
- [D2](https://d2lang.com/) - Diagram language for the schema visualization
- [Ollama](https://ollama.com/) - Local LLM for PDF import parsing
