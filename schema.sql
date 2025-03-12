create table idx (
	id integer primary key asc,
    name TEXT PRIMARY KEY,
    url TEXT
);

create table com (
	id integer primary key asc,
    isin text,
    name text,
    url text,
    index integer,
    foreign key (index) references idx(id) 
);

