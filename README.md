## Usage
Parse all indeces provided in `init.sql` and add their companies to the `com` table with:
````
python index.py
````

## Tools
- conda: https://docs.conda.io/projects/conda/en/4.6.1/user-guide/tasks/manage-environments.html
- sqlite3 cli: https://sqlite.org/cli.html

## Setup
### Python environment
cd doddsville
````
conda activate dv
````

### DB
````
sqlite3 data.db
sqlite3> .read schema.sql
````
