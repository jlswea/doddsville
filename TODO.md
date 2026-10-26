# TODO

Prioritised with MoSCoW.

## Must

- CLI tests for the Zig binary: port the scenarios from `test_cli.py` that matter
  (account, add, list, edit, report, doc, import) so they run against `dv` itself.
  Prerequisite for deleting the Python code.
- Model bookings that are not buy/sell/dividend/interest/deposit/withdrawal/transfer:
  tax refunds and withheld taxes (Kapitalertragsteuer, Solidaritätszuschlag,
  Kirchensteuer, Quellensteuer), Vorabpauschale, fees on their own, and anything
  that needs to be deferred to another period. `dv import` currently lists these
  as "not importable". Decide the ledger model first (see below).
- Ledger model for a balance sheet and tax reporting: likely double-entry (asset,
  liability, equity, income and expense accounts with balanced postings) instead
  of typed single-entry rows. Covers deferrals/accruals if needed and the figures
  for Anlage KAP (gains and losses per Verlusttopf, withheld and creditable taxes).

## Should

- Bind the Paperless token to dv instead of `/usr/bin/security`. Keychain items
  created with `security add-generic-password` trust `security` itself, so any
  process running as the user can read the token without a prompt. Options: read
  it via Security.framework from a code-signed dv, or use passage with
  age-plugin-se (Secure Enclave, Touch ID per use).
- Look up securities on demand instead of pre-filling the table: `dv security
  lookup <ISIN>` via OpenFIGI, or offline from the Xetra "All tradable
  instruments" CSV; `dv security refresh` fills the many blank names.
- Delete the Python code once the Zig CLI tests exist: CLI, TUI, sensors,
  `demo.py`, `schema.sql`, pixi/pyproject, the README section; drop the v5 guard.

## Could

- Web view for imports (`dv serve`): drop a PDF, preview it next to an editable
  transaction table, tab through cells, commit. Served on 127.0.0.1 with the UI
  embedded via `@embedFile`, driven by `importer.zig` (read → parse → check →
  commit). Highlighting a field's source in the PDF needs the parsers to record
  which words each value came from.

## Won't

- Fundamentals (revenue, cash flow) scraped from tagesschau company pages.
  Investing passively now; revisit if that changes.
- Porting the index/justETF sensors: on-demand lookup replaces them.
