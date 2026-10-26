# TODO

Prioritised with MoSCoW.

## Must

## Should

- Bind the Paperless token to dv instead of `/usr/bin/security`. Keychain items
  created with `security add-generic-password` trust `security` itself, so any
  process running as the user can read the token without a prompt. Options: read
  it via Security.framework from a code-signed dv, or use passage with
  age-plugin-se (Secure Enclave, Touch ID per use).

## Could

- Web view for imports (`dv serve`): drop a PDF, preview it next to an editable
  transaction table, tab through cells, commit. Served on 127.0.0.1 with the UI
  embedded via `@embedFile`, driven by `importer.zig` (read → parse → check →
  commit). Highlighting a field's source in the PDF needs the parsers to record
  which words each value came from.

## Won't
