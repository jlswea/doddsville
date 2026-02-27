create table security (
	id integer primary key asc,
	isin text,
	name text,
	url text,
	type text default 'stock'
);

create table account (
	id integer primary key asc,
	name text not null unique
);

create table "transaction" (
	id integer primary key asc,
	account integer not null references account (id),
	security integer references security (id), -- null for type interest, deposit, withdrawal, transfer
	type text check (type in (
		'buy',        -- Purchase stock/ETF
		'sell',       -- Sell stock/ETF
		'dividend',   -- Dividend from stock/ETF
		'interest',   -- Interest on cash balance
		'deposit',    -- Deposit / Contribution (Money coming in from outside)
		'withdrawal', -- Withdrawal (Money leaving the system)
		'transfer'    -- Internal Transfer between accounts
	)),
	total_value integer,    -- Total value of the transaction in original currency (cents)
	unit_value integer,     -- Per unit value in original currency (cents)
	quantity integer,       -- Number of shares for buy, sell, defaults to 1 for other types
	cost integer,           -- costs (fees, tax, etc.) in EUR cents
	date date not null,
	linked_transaction integer references "transaction" (id), -- Double entry for transfers
	currency text default 'EUR',    -- Currency of total_value and unit_value (e.g., USD, EUR)
	exchange_rate real default 1.0, -- Multiplier to convert to EUR
	foreign key (security) references security (id) on delete cascade
);

create table transaction_document (
	id integer primary key asc,
	transaction_id integer not null references "transaction" (id) on delete cascade,
	paperless_id integer not null,
	unique(transaction_id, paperless_id)
);

PRAGMA user_version = 4;
