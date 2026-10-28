# TODO

Prioritised with MoSCoW.

## Must

- CLI tests for the Zig binary: scenarios for broker, add, list, edit (with replay),
  report, doc and import that run against `dv` itself. The Python tests are gone.
- Bookings beyond the shortcuts: `dv add txn` with free postings, tax refunds and
  withheld taxes from Kontoauszüge in the parsers, the Vorabpauschale, and deferrals
  to another period. The journal already holds them.
- Balance sheet, income statement and the yearly tax helper (Anlage KAP: gains and
  losses per Verlusttopf, withheld and creditable taxes).

## Should

- Bind the Paperless token to dv instead of `/usr/bin/security`. Keychain items
  created with `security add-generic-password` trust `security` itself, so any
  process running as the user can read the token without a prompt. Options: read
  it via Security.framework from a code-signed dv, or use passage with
  age-plugin-se (Secure Enclave, Touch ID per use).
- Look up securities on demand instead of pre-filling the table: `dv security
  lookup <ISIN>` via OpenFIGI, or offline from the Xetra "All tradable
  instruments" CSV; `dv security refresh` fills the many blank names.
- Replace the Python sensors with the on-demand lookup above, then drop pixi.

## Could

- Web view for imports (`dv serve`): drop a PDF, preview it next to an editable
  transaction table, tab through cells, commit. Served on 127.0.0.1 with the UI
  embedded via `@embedFile`, driven by `importer.zig` (read → parse → check →
  commit). Highlighting a field's source in the PDF needs the parsers to record
  which words each value came from.

## Won't

- Fundamentals (revenue, cash flow) scraped from tagesschau company pages.
- Porting the index/justETF sensors: on-demand lookup replaces them.
