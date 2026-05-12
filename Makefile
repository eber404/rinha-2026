.PHONY: benchmark build up preprocess test clean

OFFICIAL_REPO_DIR := .cache/rinha-official
OFFICIAL_REPO_URL := https://github.com/zanfranceschi/rinha-de-backend-2026
BENCHMARK_FILE := shared/benchmarks/$(shell date +%Y-%m-%d-%H%M%S).json

UID := $(shell id -u)
GID := $(shell id -g)

DOCKER_RUN := docker-compose run --rm --user $(UID):$(GID)

build:
	@echo "Building load-balancer..."
	$(DOCKER_RUN) load-balancer zig build-exe src/main.zig -O ReleaseSmall -target aarch64-linux-musl -lc -femit-bin=main
	@echo "Building fraud-api..."
	$(DOCKER_RUN) fraud-api-1 zig build-exe src/main.zig -O ReleaseSmall -target aarch64-linux-musl -lc -femit-bin=main

up:
	docker-compose up --build

preprocess:
	@cd fraud-api && ./scripts/pre-processing.sh

test:
	@echo "Testing load-balancer..."
	$(DOCKER_RUN) load-balancer zig test --cache-dir /tmp/zig-cache --global-cache-dir /tmp/zig-global-cache tests/main_test.zig
	@echo "Testing fraud-api..."
	$(DOCKER_RUN) fraud-api-1 zig test --cache-dir /tmp/zig-cache --global-cache-dir /tmp/zig-global-cache tests/main_test.zig

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