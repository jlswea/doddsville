# Doddsville
A personal finance ledger.

## Zig CLI

### Build

```bash
brew install zig          # needs 0.17.x
zig build                 # debug build -> zig-out/bin/dv
zig build -Doptimize=ReleaseSafe   # optimised, still bounds-checked (~3 MB)
zig build test            # unit tests
zig build run -- report summary    # run without installing
```

SQLite (the official amalgamation) is a `build.zig.zon` dependency, downloaded on the
first build and compiled into the binary, so there are no system dependencies. To
upgrade, point `zig fetch` at a newer zip from https://sqlite.org/download.html:

```bash
zig fetch --save=sqlite https://www.sqlite.org/2025/sqlite-amalgamation-3500400.zip
```

Put the binary on your PATH, e.g. `ln -s "$PWD/zig-out/bin/dv" ~/.local/bin/dv`.

### Configuration

Settings live in `~/.config/doddsville/config.zon` (or `$XDG_CONFIG_HOME/doddsville/`).
Without that file `dv` uses `data.db` in the current directory; `--db` always wins.

```zig
.{
    .db = "/Users/me/doddsville/data.db",
    .paperless = .{ .url = "http://nas:8000", .keychain = "doddsville-paperless" },
    .ledger = .{ .owner = "Me" },
}
```

`.ledger` names the owner of asset accounts, the accounts bookings go to and, per
broker, its cash and depot account (default `Assets:<broker>:Cash` and `:Depot`).
Everything has defaults; `dv config show` prints them and `dv config check` flags
names under the wrong top-level account.

The Paperless token is read from that macOS Keychain item:

```bash
security add-generic-password -U -a dv -s doddsville-paperless -w   # prompts for the token
dv config check
```

### Ledger

Transactions are double-entry: each one has postings on accounts that sum to zero.
[docs/ledger-model.md](docs/ledger-model.md) explains the model, FIFO lots and how the
reports follow from the postings.

```bash
dv broker add Scalable                          # a broker -a can refer to
dv add deposit 1000.00 -a Scalable
dv add buy US0378331005 10 150.00 -c 1.00 -a Scalable    # security by name or ISIN
dv add sell US0378331005 5 160.00 -c 1.00 -a Scalable    # FIFO, gain booked
dv add dividend US0378331005 25.00 -c 3.75 -a Scalable   # -c: tax withheld
dv add transfer 500.00 --from Scalable --to Bank
dv list [-a Scalable] [-t buy]
dv edit 42                      # correct or delete; later sales are recomputed
dv report summary|balance|cashflow|holdings|performance [-a ...] [--from DD.MM.YYYY] [--to ...]
dv account list                 # ledger accounts; dv account add Expenses:Foo
dv ledger export > dv.beancount # check with bean-check, browse with Fava
```

Databases from before the journal (schema < 9) are converted on the first run: the old
rows become journal transactions with the same ids, a copy of the file is saved next to
it as `<db>.before-journal.db`, and the old tables are dropped.

### Paperless-ngx

```bash
dv add buy ... --doc 123 ./receipt.pdf   # link by id or upload
dv doc add 42 123 ./statement.pdf        # attach to an existing transaction
dv doc edit 123                          # edit a document's metadata
```

Linked documents get a `dv_transaction_id` custom field with the transaction ids, so
Paperless points back to dv; `dv list` shows the documents as links.

### Layout

```
build.zig, build.zig.zon
src/
├── main.zig         entry point: argument specs + dispatch
├── args.zig         small argparse replacement
├── App.zig          per-run context: arena, I/O, config, db, input()
├── Config.zig       config.zon + Keychain token
├── sqlite.zig       hand-written SQLite binding (@cImport is gone in 0.17)
├── migrations.zig   PRAGMA user_version migrations
├── journal.zig      accounts, balanced transactions and their checks
├── bookings.zig     buys, sells (FIFO lots), dividends, cash bookings, replay
├── beancount.zig    the journal as beancount text
├── securities.zig   the securities table
├── format.zig       money/date parsing + formatting
├── lookup.zig       broker/security resolution
├── importer.zig     PDF import without a user interface
├── paperless.zig    paperless-ngx API via std.http.Client
├── ollama.zig       local Ollama API, the import fallback
├── ui.zig           interactive editors
├── pdf/             minimal PDF reader: objects, xref, filters, fonts, text, layout
├── parsers/         deterministic broker parsers (Scalable) + LLM answer validation
└── commands/        broker, account, add, list, edit, report, doc, config, import, ledger
```

Quantities are stored in millionths of a share, so savings-plan fractions like
`0.571234` fit; `dv add buy` accepts them with `.` or `,`.

### PDF import

```bash
dv import statement.pdf -a Scalable   # parse, preview, confirm, insert, upload
dv import statement.pdf --dry-run             # parse and preview only
dv import statement.pdf --no-upload           # skip Paperless
dv import statement.pdf --raw                 # show the extracted text
dv import statement.pdf --parser llm --model llama3.2
```

1. `src/pdf` extracts positioned words (no pdfplumber, no external tools).
2. A deterministic parser claims the document and reads it: Scalable
   Wertpapierabrechnungen (buy/sell) and Kontoauszüge (savings-plan buys, deposits,
   distributions). Parsers refuse documents that fail their own checks: ISIN check
   digits, Kurs × Stück = Kurswert, and statements must reconcile with the opening and
   closing Kontostand.
3. Only if no parser can read the document, `dv` offers to ask a local Ollama model
   (`.ollama = .{ .url = ..., .model = ... }` in `config.zon`, defaults
   `http://localhost:11434` and `mistral`). Its answer is validated like any other input.
4. Securities are matched by ISIN (and can be created from the document), likely
   duplicates of recorded transactions are skipped, and sells beyond the holdings are
   flagged. Everything is previewed and editable before it is booked into the journal.
5. The PDF is uploaded to Paperless and linked to the new transactions.

Bookings the parsers do not map yet (e.g. tax refunds on a Kontoauszug) are listed
but not imported.

## Sensors (Python)

The sensors fill the securities table with ISINs, names and types (justETF ETF
listings, index compositions from tagesschau). Run `dv` once on a new database first;
the schema is its job.

```bash
pixi install
pixi run sensor list
pixi run sensor run [justetf|tagesschau] [--dry-run]
```

They are configured in `sensors/sensors.yaml` and log to `sensors.log`.

## Tools

- [Pixi](https://pixi.sh) - Python environment for the sensors
- [SQLite CLI](https://sqlite.org/cli.html) - Database interaction
- [beancount](https://beancount.github.io/) - `bean-check` on `dv ledger export`
- [Ollama](https://ollama.com/) - Optional local LLM, the last resort for PDF import
