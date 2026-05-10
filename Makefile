.PHONY: benchmark

OFFICIAL_REPO_DIR := .cache/rinha-official
OFFICIAL_REPO_URL := https://github.com/zanfranceschi/rinha-de-backend-2026
BENCHMARK_FILE := artifacts/benchmark-$(shell date +%Y-%m-%d-%H%M%S).json

benchmark:
	@mkdir -p .cache artifacts
	@if [ ! -d "$(OFFICIAL_REPO_DIR)/.git" ]; then \
		git clone --depth 1 "$(OFFICIAL_REPO_URL)" "$(OFFICIAL_REPO_DIR)"; \
	else \
		git -C "$(OFFICIAL_REPO_DIR)" fetch --depth 1 origin main; \
		git -C "$(OFFICIAL_REPO_DIR)" reset --hard origin/main; \
	fi
	@cd "$(OFFICIAL_REPO_DIR)" && ./run.sh
	@cp "$(OFFICIAL_REPO_DIR)/test/results.json" "$(BENCHMARK_FILE)"
	@echo "Saved benchmark to $(BENCHMARK_FILE)"