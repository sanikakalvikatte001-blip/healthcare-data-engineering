# DuckDB CLI only — no Python needed.  pip install -r requirements.txt
DB ?= warehouse.duckdb

.PHONY: all build test clean
all: build test

build:            ## seed raw sources, then staging -> intermediate -> marts
	rm -f $(DB)
	duckdb -bail $(DB) < build.sql

test:             ## run SQL data tests (exit code 1 on any failure)
	duckdb -bail $(DB) < tests/run_tests.sql

clean:
	rm -f $(DB) $(DB).wal
