# HEDIS CBP warehouse - DuckDB CLI only.   pip install -r requirements.txt
DB ?= cbp.duckdb

.PHONY: all build test clean
all: build test

build:   ## raw -> staging -> intermediate -> marts, exports output/*.csv
	rm -f $(DB) $(DB).wal
	duckdb -bail $(DB) < pipeline.sql

test:    ## 23 data tests; non-zero exit code if any fails
	duckdb -bail $(DB) < tests/run_tests.sql

clean:
	rm -f $(DB) $(DB).wal
