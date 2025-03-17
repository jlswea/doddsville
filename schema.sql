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
    foreign key (com) references com on delete cascade
);

