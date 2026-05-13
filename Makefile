.PHONY: benchmark build up preprocess test clean perfloop

OFFICIAL_REPO_DIR := .cache/rinha-official
OFFICIAL_REPO_URL := https://github.com/zanfranceschi/rinha-de-backend-2026
BENCHMARK_FILE := shared/benchmarks/$(shell date +%Y-%m-%d-%H%M%S).json

UID := $(shell id -u)
GID := $(shell id -g)

DOCKER_RUN := docker run --rm

PERFLOOP_ITERATIONS ?= 3
PERF_MAX_NS ?= 999999
PERF_ITERS ?= 200
PERF_WARMUP_ITERS ?= 50
PERF_DOCKER_IMAGE ?= rinha-zig-perf:0.16.0
PERF_DATA_DIR_HOST ?= /Users/eber/dev/rinha-2026/fraud-engine/vector-index

build:
	@echo "Stopping services before rebuilding binaries..."
	@docker stop server-1 server-2 lb-zig-uring 2>/dev/null || true
	@echo "Building fraud-api..."
	$(DOCKER_RUN) fraud-api-1 zig build-exe src/main.zig -O ReleaseSmall -target aarch64-linux-musl -lc --cache-dir /tmp/zig-cache --global-cache-dir /tmp/zig-cache -femit-bin=main
	@echo "Starting services with rebuilt binaries..."
	@docker compose up -d --remove-orphans lb-zig-uring server-1 server-2

up:
	docker compose up --build

preprocess:
	@cd fraud-api && ./scripts/pre-processing.sh

test:
	@echo "Testing fraud-api..."
	docker exec -t fraud-api-1 sh -c 'cd /app && zig build test 2>&1' || \
		(echo "Containers not running, building first..." && docker compose build && docker compose up -d && \
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
		LOCAL_COMMIT=$$(git -C "$(OFFICIAL_REPO_DIR)" rev-parse HEAD); \
		REMOTE_COMMIT=$$(git -C "$(OFFICIAL_REPO_DIR)" rev-parse origin/main); \
		if [ "$$LOCAL_COMMIT" != "$$REMOTE_COMMIT" ]; then \
			if ! git -C "$(OFFICIAL_REPO_DIR)" diff --quiet "$$LOCAL_COMMIT" "$$REMOTE_COMMIT" -- test; then \
				git -C "$(OFFICIAL_REPO_DIR)" reset --hard origin/main; \
			fi; \
		fi; \
	fi
	@cd "$(OFFICIAL_REPO_DIR)" && ./run.sh
	@cp "$(OFFICIAL_REPO_DIR)/test/results.json" "$(BENCHMARK_FILE)"
	@echo "Saved benchmark to $(BENCHMARK_FILE)"

perfloop:
	@set -eu; \
	iterations="$(PERFLOOP_ITERATIONS)"; \
	if [ "$$iterations" -lt 1 ]; then \
		echo "PERFLOOP_ITERATIONS must be >= 1"; \
		exit 1; \
	fi; \
	echo "Building perf runner image ($(PERF_DOCKER_IMAGE))..."; \
	docker build -f server/Dockerfile --target zig-builder -t "$(PERF_DOCKER_IMAGE)" . >/dev/null; \
	sum=0; \
	run=1; \
	while [ $$run -le $$iterations ]; do \
		echo "Run $$run/$$iterations"; \
		set +e; \
		output="$$(docker run --rm \
			-v "$(CURDIR)":/workspace \
			-v "$(PERF_DATA_DIR_HOST)":/perf-data:ro \
			-w /workspace \
			-e RUN_PERF_TESTS=1 \
			-e PERF_DATA_DIR=/perf-data \
			-e PERF_MAX_NS=$(PERF_MAX_NS) \
			-e PERF_ITERS=$(PERF_ITERS) \
			-e PERF_WARMUP_ITERS=$(PERF_WARMUP_ITERS) \
			"$(PERF_DOCKER_IMAGE)" \
			zig test fraud-engine/src/scorer.zig -O ReleaseFast 2>&1)"; \
		status=$$?; \
		set -e; \
		printf "%s\n" "$$output"; \
		if [ $$status -ne 0 ]; then \
			echo "Run $$run failed with status $$status"; \
			exit $$status; \
		fi; \
		ns="$$(printf "%s\n" "$$output" | sed -n 's/.*ns\/op=\([0-9][0-9]*\).*/\1/p' | tail -n 1)"; \
		if [ -z "$$ns" ]; then \
			echo "Could not extract ns/op from perf output"; \
			exit 1; \
		fi; \
		echo "Run $$run result: $$ns ns/op"; \
		sum=$$((sum + ns)); \
		run=$$((run + 1)); \
	done; \
	avg=$$((sum / iterations)); \
	echo "Average over $$iterations runs: $$avg ns/op"
