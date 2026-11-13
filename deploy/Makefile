# Operator targets for the deploy/ stack.
# Default profile: (none) = timescaledb only.  PROFILE=live adds fleet-telemetry.

PROFILE      ?=
PSQL_FLAGS   := -U postgres -d tesla
PSQL_LOCAL   := docker compose exec -T timescaledb psql $(PSQL_FLAGS)
PSQL_URL     ?= postgres://postgres:$${POSTGRES_PASSWORD}@localhost:5432/tesla?sslmode=disable
FORCE        ?= 0
NGINX_HOST   ?= tesla.example.com

# systemd timers (install-timers)
REPO_DIR     := $(abspath ..)
TIMER_USER   ?= $(shell id -un)
UNITS        := tesla-backup.service tesla-backup.timer \
                tesla-weekly-report.service tesla-weekly-report.timer

.PHONY: help up down logs ps restart psql migrate migrate-status verify-coverage \
        verify-fields integration-test nginx-setup firewall-setup install-timers \
        backup reset

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  %-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ── Stack ──────────────────────────────────────────────────────────────────────

up: ## Bring stack up  (PROFILE=live to also start fleet-telemetry)
	$(if $(PROFILE),docker compose --profile $(PROFILE) up -d,docker compose up -d)

down: ## Stop & remove containers (keeps volumes)
	$(if $(PROFILE),docker compose --profile $(PROFILE) down,docker compose down)

restart: ## Restart all running containers
	$(if $(PROFILE),docker compose --profile $(PROFILE) restart,docker compose restart)

logs: ## Tail logs
	$(if $(PROFILE),docker compose --profile $(PROFILE) logs -f,docker compose logs -f)

ps: ## Show service status
	$(if $(PROFILE),docker compose --profile $(PROFILE) ps,docker compose ps)

psql: ## Open psql shell against the local database
	docker compose exec timescaledb psql $(PSQL_FLAGS)

# ── Migrations ─────────────────────────────────────────────────────────────────

migrate: ## Apply outstanding SQL migrations in dependency order (FORCE=1 re-applies all)
	docker compose exec -T -e FORCE=$(FORCE) -e POSTGRES_DB=tesla timescaledb \
	  bash /docker-entrypoint-initdb.d/00_apply_migrations.sh

migrate-status: ## Show which migrations have been applied
	$(PSQL_LOCAL) -c "SELECT filename, applied_at FROM schema_migrations ORDER BY applied_at"

# ── Verification ───────────────────────────────────────────────────────────────

verify-coverage: ## Field coverage: how many of the 239 catalog fields have data
	$(PSQL_LOCAL) -c \
	  "SELECT fc.category, COUNT(*) FILTER (WHERE t.field IS NOT NULL) AS seen, COUNT(*) AS total \
	   FROM field_catalog fc LEFT JOIN telemetry_latest t ON t.field=fc.field \
	   GROUP BY fc.category ORDER BY 1"

verify-fields: ## Top fields by sample count (last hour)
	$(PSQL_LOCAL) -c \
	  "SELECT field, COUNT(*) AS samples, MAX(ts) AS last_seen \
	   FROM telemetry WHERE ts > NOW() - INTERVAL '1 hour' \
	   GROUP BY field ORDER BY samples DESC LIMIT 25"

# ── Tests ──────────────────────────────────────────────────────────────────────

integration-test: ## Run integration tests against the running database
	cd .. && TEST_PG_DSN='$(PSQL_URL)' go test -tags=integration ./datastore/postgres/...

# ── Server setup (run once on a fresh production box) ────────────────────────────────

nginx-setup: ## Install nginx vhost (override the host with NGINX_HOST=your.domain)
	@echo "Creating /etc/nginx/sites-available/$(NGINX_HOST) from nginx/tesla.example.com.conf"
	sed 's/tesla\.example\.com/$(NGINX_HOST)/g' nginx/tesla.example.com.conf \
	  | sudo tee /etc/nginx/sites-available/$(NGINX_HOST) > /dev/null
	sudo ln -sf /etc/nginx/sites-available/$(NGINX_HOST) /etc/nginx/sites-enabled/
	sudo nginx -t && sudo systemctl reload nginx
	@echo "Now run: sudo certbot --nginx -d $(NGINX_HOST)"

firewall-setup: ## Open UFW ports needed for the tesla stack
	sudo ufw allow 4443/tcp comment "fleet-telemetry mTLS (Tesla cars)"
	@# No rule for 5432: the database is published on 127.0.0.1 only, so a
	@# firewall rule for it has no effect. Reach it through SSH or a tunnel.
	sudo ufw status numbered

install-timers: ## Install + enable the nightly backup and weekly report systemd timers
	@for u in $(UNITS); do \
	  sed -e 's|@REPO@|$(REPO_DIR)|g' -e 's|@USER@|$(TIMER_USER)|g' systemd/$$u \
	    | sudo tee /etc/systemd/system/$$u > /dev/null || exit 1; \
	  echo "installed /etc/systemd/system/$$u"; \
	done
	sudo systemctl daemon-reload
	sudo systemctl enable --now tesla-backup.timer tesla-weekly-report.timer
	systemctl list-timers 'tesla-*' --no-pager

backup: ## Run a backup now (same script the timer runs)
	../tools/backup.sh

# ── Danger zone ────────────────────────────────────────────────────────────────

reset: ## Print the commands that wipe the database (does not run them)
	@# Deliberately not automated: a recursive delete driven by a variable is
	@# one typo away from removing the wrong tree. The data directory is the one
	@# compose actually mounts (PGDATA_DIR in .env, default /u01/tesla/pgdata);
	@# the commands below are printed with that resolved path for an operator to
	@# check and run by hand. Take a backup first (make backup).
	@dir=$$(docker compose config --format json 2>/dev/null \
	  | python3 -c 'import json,sys; v=json.load(sys.stdin)["services"]["timescaledb"]["volumes"]; print(next(x["source"] for x in v if x["target"]=="/home/postgres/pgdata/data"))' 2>/dev/null); \
	if [ -z "$$dir" ]; then echo "reset: could not resolve the database data directory from docker compose config" >&2; exit 1; fi; \
	echo "This would DELETE ALL telemetry data in: $$dir"; \
	echo "To do it, check the path and run:"; \
	echo "  docker compose --profile live --profile notify down"; \
	echo "  sudo rm -rf -- '$$dir'"; \
	echo "  docker compose --profile live --profile notify up -d   # re-initialises an empty database"
