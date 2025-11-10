create table idx (
	id integer primary key asc,
    name text,
    url text
);

create table com (
	id integer primary key asc,
    isin text,
    name text,
    url text
);

create table raw (
    id integer primary key asc,
    com integer,
    html text,
    timestamp text, 
    foreign key (com) references com (id) on delete cascade
);

create table trans (
	id integer primary key asc,
	com integer,
	type text,
	amount integer,
	date date,
	price integer, -- price per share in euro cents
	cost integer, -- costs (fees, tax, etc.) in euro cents
	foreign key (com) references com (id) on delete cascade,
	check (type in ('buy', 'sell'))
);

