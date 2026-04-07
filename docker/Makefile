COMPOSE  = docker compose
ENV_FILE = .env
GEN_ENV  = gen-env.txt

.PHONY: help init aha-up provision up down restart logs clean

help:
	@echo "Synapse CTI — Docker Deployment"
	@echo ""
	@echo "First-time setup:"
	@echo "  1. make aha-up     Start AHA (service discovery)"
	@echo "  2. make provision  Generate provisioning URLs via env-getter.sh"
	@echo "  3. Copy lines from $(GEN_ENV) into $(ENV_FILE)"
	@echo "  4. make up         Start all services"
	@echo ""
	@echo "  Shortcut: 'make init' runs steps 1-2 in one go."
	@echo ""
	@echo "Day-to-day:"
	@echo "  up       Start all services"
	@echo "  down     Stop all services"
	@echo "  restart  Restart all services"
	@echo "  logs     Tail logs for all services"
	@echo "  clean    Stop services and delete named volumes (destructive)"

# Start AHA only (first step of provisioning workflow)
aha-up:
	$(COMPOSE) up -d aha

# Run env-getter.sh to generate provisioning URLs into gen-env.txt
provision:
	@rm -f $(GEN_ENV)
	@sh env-getter.sh
	@echo ""
	@echo "Provisioning URLs written to $(GEN_ENV):"
	@echo "---"
	@cat $(GEN_ENV)
	@echo "---"
	@echo "Copy the lines above into $(ENV_FILE), then run 'make up'."

# Combined: start AHA, wait for healthy, then provision
init: aha-up
	@echo "Waiting for AHA to become healthy..."
	@until $(COMPOSE) ps aha | grep -q "(healthy)"; do \
		printf '.'; sleep 3; \
	done
	@echo ""
	@$(MAKE) provision

# Start all services (requires $(ENV_FILE) to be populated)
up:
	$(COMPOSE) --env-file $(ENV_FILE) up -d

# Stop all services (containers removed, volumes preserved)
down:
	$(COMPOSE) down

# Restart running services
restart:
	$(COMPOSE) restart

# Tail logs for all services
logs:
	$(COMPOSE) logs -f

# Stop services and delete all named volumes (data loss — use with care)
clean:
	$(COMPOSE) down -v
