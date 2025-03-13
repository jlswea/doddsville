create table idx (
	id integer primary key asc,
    name text,
    url text
);

create table com (
	id integer primary key asc,
    isin text,
    name text,
    url text,
    idx integer,
    foreign key (idx) references idx(id) 
);

