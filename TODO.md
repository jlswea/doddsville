# TODO

- Bind the Paperless token to dv instead of `/usr/bin/security`. Keychain items
  created with `security add-generic-password` trust `security` itself, so any
  process running as the user can read the token without a prompt. Options: read
  it via Security.framework from a code-signed dv, or use passage with
  age-plugin-se (Secure Enclave, Touch ID per use).
