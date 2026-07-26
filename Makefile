# Noble outbound system of record — send-eligible pipeline
#
#   make up        start Postgres in Docker
#   make load      create the schema and load the raw CSV
#   make eligible  resolve identity, apply the rules, write out/
#   make test      run the assertion suite
#   make verify    run the pipeline twice and prove the output is identical
#   make down      stop and remove the container
#
#   make all       up -> load -> eligible -> test
#
# DATABASE_URL is overridable, so the pipeline can be pointed at any Postgres
# 16 — a local install, a read replica, a colleague's instance — without
# Docker. Nothing below assumes the container.

DATABASE_URL ?= postgresql://noble:noble@localhost:5433/noble
PSQL         ?= psql
PSQL_RUN      = $(PSQL) "$(DATABASE_URL)" -v ON_ERROR_STOP=1 --quiet

# The date every clock is evaluated against. Passed in rather than read from
# now(), so the counts in tests/ reproduce tomorrow. Override to see the
# recycle windows move:  make eligible AS_OF=2026-12-01
AS_OF      ?= 2026-07-25
EXPERIMENT ?= aeo-saas-aug

CSV        := noble-outbound-contacts.csv
OUT        := out

.PHONY: all up down load eligible test verify clean psql

all: up load eligible test

up:
	docker compose up -d --wait
	@echo "postgres ready on $(DATABASE_URL)"

down:
	docker compose down -v

# Schema first, then the raw file. Kept separate from `eligible` because the
# landing table is the thing you go back to when you disagree with a number,
# and it should not be reloaded just to re-run the rules.
load:
	$(PSQL_RUN) -f sql/01_schema.sql
	$(PSQL_RUN) -f sql/02_load.sql
	@echo "loaded $(CSV)"

eligible: $(OUT)
	$(PSQL_RUN) -c "UPDATE config.setting SET value = '$(AS_OF)'      WHERE key = 'as_of'"
	$(PSQL_RUN) -c "UPDATE config.setting SET value = '$(EXPERIMENT)' WHERE key = 'experiment'"
	$(PSQL_RUN) -f sql/03_identity.sql
	$(PSQL_RUN) -f sql/04_events.sql
	$(PSQL_RUN) -f sql/05_domain_lock.sql
	$(PSQL_RUN) -f sql/06_eligibility.sql
	$(PSQL_RUN) -f sql/07_export.sql
	$(PSQL) "$(DATABASE_URL)" -v ON_ERROR_STOP=1 -f sql/08_summary.sql

test:
	$(PSQL) "$(DATABASE_URL)" -v ON_ERROR_STOP=1 --quiet \
	    -f tests/00_harness.sql \
	    -f tests/10_identity_test.sql \
	    -f tests/20_domain_lock_test.sql \
	    -f tests/30_eligibility_test.sql \
	    -f tests/40_reconciliation_test.sql \
	    -f tests/50_channel_scoping_test.sql \
	    -f tests/99_report.sql

# Idempotence, checked rather than claimed. Issue 07 requires that running the
# pipeline twice produces identical output and does not double-enrol anyone;
# a byte-for-byte diff of both artifacts is the strongest available statement
# of that, and it is what catches a stray gen_random_uuid() or an ORDER BY
# that depends on physical row order.
verify: eligible
	@rm -rf $(OUT)/.verify && mkdir -p $(OUT)/.verify && cp $(OUT)/*.csv $(OUT)/.verify/
	@$(MAKE) --no-print-directory eligible >/dev/null
	@for f in $(OUT)/*.csv; do \
	    diff -q "$$f" "$(OUT)/.verify/$$(basename $$f)" >/dev/null \
	      || { echo "NOT IDEMPOTENT: $$f differs between runs"; exit 1; }; \
	done
	@rm -rf $(OUT)/.verify
	@echo "idempotent: two runs produced byte-identical artifacts"

psql:
	$(PSQL) "$(DATABASE_URL)"

$(OUT):
	mkdir -p $(OUT)

clean:
	rm -rf $(OUT)
