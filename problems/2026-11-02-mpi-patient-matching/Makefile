# Master Patient Index on PostgreSQL.
# Connection comes from the standard libpq variables (PGHOST, PGPORT, PGUSER,
# PGPASSWORD, PGDATABASE). Defaults suit a local cluster.
export PGDATABASE ?= mpi_demo
export PGHOST     ?= localhost
export PGUSER     ?= postgres

PSQL       = psql -X -q -v ON_ERROR_STOP=1
MIGRATIONS = $(sort $(wildcard db/migrations/V*.sql))

.PHONY: all db migrate seed run report test clean

all: run report

db:            ## create the database if it does not exist
	@psql -X -q -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '$(PGDATABASE)'" | grep -q 1 \
	  || createdb $(PGDATABASE)

migrate: db    ## (re)build schemas, functions, procedure
	@for f in $(MIGRATIONS); do echo ">> $$f"; $(PSQL) -f $$f || exit 1; done

seed: migrate  ## generate the synthetic registration feed
	@$(PSQL) -f db/seed/synthetic_registrations.sql

run: seed      ## process both batches in arrival order
	@$(PSQL) -c "CALL mpi.process_batch('B20261101')"
	@$(PSQL) -c "CALL mpi.process_batch('B20261102')"

report:        ## print volumes, decisions and accuracy
	@$(PSQL) -f reports/match_quality.sql

test: run      ## pgTAP suite (needs the pgtap extension and pg_prove)
	@$(PSQL) -c "CREATE EXTENSION IF NOT EXISTS pgtap"
	@pg_prove --ext .sql tests/

clean:
	@dropdb --if-exists $(PGDATABASE)
