.PHONY: test-official

OFFICIAL_REPO_DIR := .cache/rinha-official
OFFICIAL_REPO_URL := https://github.com/zanfranceschi/rinha-de-backend-2026
RESULT_FILE := artifacts/rinha-official-result.json

test-official:
	@mkdir -p .cache artifacts
	@if [ ! -d "$(OFFICIAL_REPO_DIR)/.git" ]; then \
		git clone --depth 1 "$(OFFICIAL_REPO_URL)" "$(OFFICIAL_REPO_DIR)"; \
	else \
		git -C "$(OFFICIAL_REPO_DIR)" fetch --depth 1 origin main; \
		git -C "$(OFFICIAL_REPO_DIR)" reset --hard origin/main; \
	fi
	@cd "$(OFFICIAL_REPO_DIR)" && ./run.sh
	@cp "$(OFFICIAL_REPO_DIR)/test/results.json" "$(RESULT_FILE)"
	@echo "Saved official result to $(RESULT_FILE)"
