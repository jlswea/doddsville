-- Initial database schema
-- depends:

CREATE TABLE IF NOT EXISTS "index" (
    id INTEGER PRIMARY KEY ASC,
    name TEXT,
    url TEXT
);

CREATE TABLE IF NOT EXISTS company (
    id INTEGER PRIMARY KEY ASC,
    isin TEXT,
    name TEXT,
    url TEXT
);

CREATE TABLE IF NOT EXISTS raw_html (
    id INTEGER PRIMARY KEY ASC,
    com INTEGER,
    html TEXT,
    timestamp TEXT,
    FOREIGN KEY (com) REFERENCES company (id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS account (
    id INTEGER PRIMARY KEY ASC,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS "transaction" (
    id INTEGER PRIMARY KEY ASC,
    account INTEGER NOT NULL REFERENCES account (id),
    company INTEGER REFERENCES company (id),
    type TEXT CHECK (type IN (
        'buy',
        'sell',
        'dividend',
        'interest',
        'deposit',
        'withdrawal',
        'transfer'
    )),
    total_value INTEGER,
    unit_value INTEGER,
    quantity INTEGER,
    cost INTEGER,
    date DATE NOT NULL,
    linked_transaction INTEGER REFERENCES "transaction" (id),
    FOREIGN KEY (company) REFERENCES company (id) ON DELETE CASCADE
);
