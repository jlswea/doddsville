create table "index" (
	id integer primary key asc,
	name text,
	url text
);

create table company (
	id integer primary key asc,
	isin text,
	name text,
	url text
);

create table raw_html (
	id integer primary key asc,
	com integer,
	html text,
	timestamp text,
	foreign key (com) references company (id) on delete cascade
);

create table account (
	id integer primary key asc,
	name text not null unique
);

create table "transaction" (
	id integer primary key asc,
	account integer not null references account (id),
	company integer references company (id), -- null for type interest, deposit, withdrawal, transfer
	type text check (type in (
		'buy',        -- Purchase stock
		'sell',       -- Sell stock
		'dividend',   -- Dividend from stock
		'interest',   -- Interest on cash balance
		'deposit',    -- Deposit / Contribution (Money coming in from outside)
		'withdrawal', -- Withdrawal (Money leaving the system)
		'transfer'    -- Internal Transfer between accounts
	)),
	total_value integer,    -- Total value of the transaction in cents
	unit_value integer,     -- Per unit value in cents
	quantity integer,       -- Number of shares for buy, sell, defaults to 1 for other types
	cost integer,           -- costs (fees, tax, etc.) in cents
	date date not null,
	linked_transaction integer references "transaction" (id), -- Double entry for transfers
	foreign key (company) references company (id) on delete cascade
);

create table transaction_document (
	id integer primary key asc,
	transaction_id integer not null references "transaction" (id) on delete cascade,
	paperless_id integer not null,
	unique(transaction_id, paperless_id)
);
