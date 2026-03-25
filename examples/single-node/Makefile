# ============================================
# Single-Node Stack Makefile
# Common operations for managing the stack
# ============================================

# Configuration
COMPOSE_FILE := docker-compose.yml
ENV_FILE := .env
PROJECT_NAME := single-node-stack

# Colors for output
BLUE := \033[36m
GREEN := \033[32m
YELLOW := \033[33m
RED := \033[31m
NC := \033[0m

.PHONY: help setup start stop restart logs ps clean backup restore health

# Default target
help:
	@echo "$(BLUE)Single-Node Stack Management$(NC)"
	@echo ""
	@echo "$(GREEN)Setup Commands:$(NC)"
	@echo "  make setup          - Initial setup (create dirs, copy env file)"
	@echo "  make setup-quadlet  - Setup Quadlet files for systemd"
	@echo ""
	@echo "$(GREEN)Container Commands:$(NC)"
	@echo "  make start          - Start all services"
	@echo "  make stop           - Stop all services"
	@echo "  make restart        - Restart all services"
	@echo "  make pull           - Pull latest images"
	@echo "  make build          - Build images (if needed)"
	@echo ""
	@echo "$(GREEN)Monitoring Commands:$(NC)"
	@echo "  make logs           - View all logs"
	@echo "  make logs-app       - View application logs"
	@echo "  make logs-db        - View database logs"
	@echo "  make ps             - List running containers"
	@echo "  make health         - Check health of all services"
	@echo "  make stats          - Show container statistics"
	@echo ""
	@echo "$(GREEN)Database Commands:$(NC)"
	@echo "  make db-shell       - Open PostgreSQL shell"
	@echo "  make db-backup      - Create database backup"
	@echo "  make db-restore     - Restore database from backup"
	@echo "  make redis-cli      - Open Redis CLI"
	@echo ""
	@echo "$(GREEN)Maintenance Commands:$(NC)"
	@echo "  make clean          - Stop and remove containers, networks"
	@echo "  make clean-volumes  - Clean + remove all volumes (DATA LOSS!)"
	@echo "  make update         - Pull updates and restart"
	@echo "  make backup         - Create full backup"
	@echo ""
	@echo "$(GREEN)Security Commands:$(NC)"
	@echo "  make security-scan  - Scan images for vulnerabilities"
	@echo "  make rotate-secrets - Generate new random passwords"

# ============================================
# Setup Commands
# ============================================
setup:
	@echo "$(BLUE)Setting up single-node stack...$(NC)"
	@mkdir -p nginx/conf.d init-scripts backups app/config redis
	@test -f $(ENV_FILE) || cp .env.example $(ENV_FILE)
	@echo "$(GREEN)Setup complete! Edit $(ENV_FILE) with your settings.$(NC)"
	@echo "$(YELLOW)IMPORTANT: Change default passwords in $(ENV_FILE)!$(NC)"

setup-quadlet:
	@echo "$(BLUE)Setting up Quadlet files...$(NC)"
	@mkdir -p ~/.config/containers/systemd
	@cp quadlets/*.container quadlets/*.network quadlets/*.volume ~/.config/containers/systemd/ 2>/dev/null || true
	@systemctl --user daemon-reload 2>/dev/null || echo "$(YELLOW)Run: systemctl --user daemon-reload$(NC)"
	@echo "$(GREEN)Quadlet files installed. Use: systemctl --user start nginx-proxy$(NC)"

# ============================================
# Container Commands
# ============================================
start:
	@echo "$(BLUE)Starting services...$(NC)"
	podman-compose -f $(COMPOSE_FILE) --env-file $(ENV_FILE) up -d
	@echo "$(GREEN)Services started!$(NC)"
	@make --no-print-directory health

stop:
	@echo "$(BLUE)Stopping services...$(NC)"
	podman-compose -f $(COMPOSE_FILE) down
	@echo "$(GREEN)Services stopped.$(NC)"

restart:
	@echo "$(BLUE)Restarting services...$(NC)"
	podman-compose -f $(COMPOSE_FILE) restart
	@make --no-print-directory health

pull:
	@echo "$(BLUE)Pulling latest images...$(NC)"
	podman-compose -f $(COMPOSE_FILE) pull

build:
	@echo "$(BLUE)Building images...$(NC)"
	podman-compose -f $(COMPOSE_FILE) build

# ============================================
# Monitoring Commands
# ============================================
logs:
	podman-compose -f $(COMPOSE_FILE) logs -f --tail=100

logs-app:
	podman-compose -f $(COMPOSE_FILE) logs -f --tail=100 app

logs-db:
	podman-compose -f $(COMPOSE_FILE) logs -f --tail=100 postgres

logs-nginx:
	podman-compose -f $(COMPOSE_FILE) logs -f --tail=100 nginx

ps:
	@echo "$(BLUE)Container Status:$(NC)"
	@podman-compose -f $(COMPOSE_FILE) ps

health:
	@echo "$(BLUE)Checking service health...$(NC)"
	@podman healthcheck run nginx-proxy 2>/dev/null && echo "$(GREEN)nginx: healthy$(NC)" || echo "$(RED)nginx: unhealthy$(NC)"
	@podman healthcheck run app-server 2>/dev/null && echo "$(GREEN)app: healthy$(NC)" || echo "$(RED)app: unhealthy$(NC)"
	@podman healthcheck run postgres-db 2>/dev/null && echo "$(GREEN)postgres: healthy$(NC)" || echo "$(RED)postgres: unhealthy$(NC)"
	@podman healthcheck run redis-cache 2>/dev/null && echo "$(GREEN)redis: healthy$(NC)" || echo "$(RED)redis: unhealthy$(NC)"

stats:
	@echo "$(BLUE)Container Statistics:$(NC)"
	@podman stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.PIDs}}"

# ============================================
# Database Commands
# ============================================
db-shell:
	@echo "$(BLUE)Opening PostgreSQL shell...$(NC)"
	@source $(ENV_FILE) && podman exec -it postgres-db psql -U $$POSTGRES_USER -d $$POSTGRES_DB

db-backup:
	@echo "$(BLUE)Creating database backup...$(NC)"
	@mkdir -p backups
	@source $(ENV_FILE) && podman exec postgres-db pg_dump -U $$POSTGRES_USER -d $$POSTGRES_DB | gzip > backups/postgres-$$(date +%Y%m%d-%H%M%S).sql.gz
	@echo "$(GREEN)Backup created in backups/$(NC)"

db-restore:
	@echo "$(YELLOW)Usage: make db-restore FILE=backups/postgres-YYYYMMDD-HHMMSS.sql.gz$(NC)"
	@if [ -f "$(FILE)" ]; then \
		echo "$(BLUE)Restoring from $(FILE)...$(NC)"; \
		gunzip < $(FILE) | podman exec -i postgres-db psql -U appuser -d appdb; \
		echo "$(GREEN)Restore complete!$(NC)"; \
	else \
		echo "$(RED)File not found: $(FILE)$(NC)"; \
	fi

redis-cli:
	@echo "$(BLUE)Opening Redis CLI...$(NC)"
	@source $(ENV_FILE) && podman exec -it redis-cache redis-cli -a $$REDIS_PASSWORD

redis-flush:
	@echo "$(RED)WARNING: This will flush all Redis data!$(NC)"
	@read -p "Type 'yes' to continue: " confirm && [ "$$confirm" = "yes" ] || exit 1
	@source $(ENV_FILE) && podman exec redis-cache redis-cli -a $$REDIS_PASSWORD FLUSHALL
	@echo "$(GREEN)Redis cache flushed.$(NC)"

# ============================================
# Maintenance Commands
# ============================================
clean:
	@echo "$(BLUE)Cleaning up containers and networks...$(NC)"
	podman-compose -f $(COMPOSE_FILE) down --remove-orphans
	@echo "$(GREEN)Cleanup complete.$(NC)"

clean-volumes:
	@echo "$(RED)WARNING: This will delete all data volumes!$(NC)"
	@read -p "Type 'DELETE' to continue: " confirm && [ "$$confirm" = "DELETE" ] || exit 1
	podman-compose -f $(COMPOSE_FILE) down -v --remove-orphans
	@echo "$(GREEN)All volumes removed.$(NC)"

update: pull restart
	@echo "$(GREEN)Update complete!$(NC)"

backup:
	@echo "$(BLUE)Creating full backup...$(NC)"
	@mkdir -p backups/full
	@make --no-print-directory db-backup
	@podman run --rm -v single-node-stack_postgres_data:/data:ro -v $$(pwd)/backups/full:/backup alpine tar czf /backup/postgres-data-$$(date +%Y%m%d).tar.gz -C /data .
	@podman run --rm -v single-node-stack_redis_data:/data:ro -v $$(pwd)/backups/full:/backup alpine tar czf /backup/redis-data-$$(date +%Y%m%d).tar.gz -C /data .
	@echo "$(GREEN)Full backup complete in backups/full/$(NC)"

# ============================================
# Security Commands
# ============================================
security-scan:
	@echo "$(BLUE)Scanning images for vulnerabilities...$(NC)"
	@podman image list --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>" | while read img; do \
		echo "$(YELLOW)Scanning: $$img$(NC)"; \
		podman image scane $$img 2>/dev/null || echo "$(RED)Scan failed for $$img$(NC)"; \
	done

rotate-secrets:
	@echo "$(BLUE)Generating new secrets...$(NC)"
	@echo "POSTGRES_PASSWORD=$$(openssl rand -base64 32)" > $(ENV_FILE).new
	@echo "REDIS_PASSWORD=$$(openssl rand -base64 32)" >> $(ENV_FILE).new
	@echo "APP_KEY=base64:$$(openssl rand -base64 32)" >> $(ENV_FILE).new
	@echo "JWT_SECRET=$$(openssl rand -base64 32)" >> $(ENV_FILE).new
	@echo "$(GREEN)New secrets generated in $(ENV_FILE).new$(NC)"
	@echo "$(YELLOW)Review and merge with your existing $(ENV_FILE)$(NC)"
