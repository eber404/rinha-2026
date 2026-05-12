.PHONY: benchmark build up preprocess test clean

OFFICIAL_REPO_DIR := .cache/rinha-official
OFFICIAL_REPO_URL := https://github.com/zanfranceschi/rinha-de-backend-2026
BENCHMARK_FILE := shared/benchmarks/$(shell date +%Y-%m-%d-%H%M%S).json

UID := $(shell id -u)
GID := $(shell id -g)

DOCKER_RUN := docker-compose run --rm

build:
	@echo "Stopping services before rebuilding binaries..."
	@docker-compose stop haproxy fraud-api-1 fraud-api-2 >/dev/null 2>&1 || true
	@echo "Building fraud-api..."
	$(DOCKER_RUN) fraud-api-1 zig build-exe src/main.zig -O ReleaseSmall -target aarch64-linux-musl -lc --cache-dir /tmp/zig-cache --global-cache-dir /tmp/zig-cache -femit-bin=main
	@echo "Starting services with rebuilt binaries..."
	@docker-compose up -d --remove-orphans haproxy fraud-api-1 fraud-api-2

up:
	docker-compose up --build

preprocess:
	@cd fraud-api && ./scripts/pre-processing.sh

test:
	@echo "Testing fraud-api..."
	docker exec -t fraud-api-1 sh -c 'cd /app && zig build test 2>&1' || \
		(echo "Containers not running, building first..." && docker-compose build && docker-compose up -d && \
		docker exec -t fraud-api-1 sh -c 'cd /app && zig build test 2>&1')
	@echo "All tests passed!"

clean:
	@echo "Cleaning artifacts..."
	@rm -f load-balancer/main fraud-api/main
	@rm -rf load-balancer/.zig-cache fraud-api/.zig-cache
	@rm -rf load-balancer/zig-out fraud-api/zig-out

benchmark:
	@mkdir -p .cache shared/benchmarks
	@if [ ! -d "$(OFFICIAL_REPO_DIR)/.git" ]; then \
		git clone --depth 1 "$(OFFICIAL_REPO_URL)" "$(OFFICIAL_REPO_DIR)"; \
	else \
		git -C "$(OFFICIAL_REPO_DIR)" fetch --depth 1 origin main; \
		git -C "$(OFFICIAL_REPO_DIR)" reset --hard origin/main; \
	fi
	@cd "$(OFFICIAL_REPO_DIR)" && ./run.sh
	@cp "$(OFFICIAL_REPO_DIR)/test/results.json" "$(BENCHMARK_FILE)"
	@echo "Saved benchmark to $(BENCHMARK_FILE)"
