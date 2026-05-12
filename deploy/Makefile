# Operator targets for the deploy/ stack.
# Default profile: (none) = timescaledb only.  PROFILE=live adds fleet-telemetry.

PROFILE      ?=
PSQL_FLAGS   := -U postgres -d tesla
PSQL_LOCAL   := docker compose exec -T timescaledb psql $(PSQL_FLAGS)
PSQL_URL     ?= postgres://postgres:changeme@localhost:5432/tesla?sslmode=disable

.PHONY: help up down logs ps restart psql migrate verify-coverage verify-fields \
        integration-test nginx-setup firewall-setup reset

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

migrate: ## Re-apply all SQL migrations (idempotent)
	@for f in sql/001_schema.sql sql/002_views.sql sql/003_grafana_role.sql sql/004_field_catalog.sql; do \
	  echo ">>> $$f"; \
	  docker compose exec -T timescaledb psql $(PSQL_FLAGS) -f /docker-entrypoint-initdb.d/$$(basename $$f); \
	done

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

nginx-setup: ## Install nginx vhost for tesla.example.com (run as <your-user> on prod server)
	@echo "Creating /etc/nginx/sites-available/tesla.example.com"
	sudo cp nginx/tesla.example.com.conf /etc/nginx/sites-available/tesla.example.com
	sudo ln -sf /etc/nginx/sites-available/tesla.example.com /etc/nginx/sites-enabled/
	sudo nginx -t && sudo systemctl reload nginx
	@echo "Now run: sudo certbot --nginx -d tesla.example.com"

firewall-setup: ## Open UFW ports needed for the tesla stack
	sudo ufw allow 4443/tcp comment "fleet-telemetry mTLS (Tesla cars)"
	# sudo ufw allow from 10.10.0.0/24 to any port 5432 proto tcp comment "TimescaleDB from VPN (optional)"
	sudo ufw status numbered

# ── Danger zone ────────────────────────────────────────────────────────────────

reset: ## STOP everything and DELETE the database volume  ⚠ irreversible
	@read -p "This will delete ALL telemetry data. Type 'yes' to continue: " c; \
	if [ "$$c" = "yes" ]; then \
	  docker compose down; \
	  sudo rm -rf /u01/tesla/pgdata; \
	  echo "Done."; \
	else \
	  echo "aborted"; \
	fi
