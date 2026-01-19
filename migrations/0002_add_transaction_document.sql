-- Add transaction_document table for paperless-ngx integration
-- depends: 0001_initial_schema

CREATE TABLE IF NOT EXISTS transaction_document (
    id INTEGER PRIMARY KEY ASC,
    transaction_id INTEGER NOT NULL REFERENCES "transaction" (id) ON DELETE CASCADE,
    paperless_id INTEGER NOT NULL,
    UNIQUE(transaction_id, paperless_id)
);
