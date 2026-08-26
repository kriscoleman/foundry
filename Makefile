# Auto-discover mold directories (any subdir of molds/ with mold.yaml).
MOLDS := $(patsubst molds/%/mold.yaml,%,$(wildcard molds/*/mold.yaml))

AILLOY_VERSION ?= v0.6.34

.PHONY: test lint temper assay check-links deps cast-test help

## Default: run all fast checks (ailloy auto-installs if missing)
test: lint

## Run all local linting
lint: check-links temper assay

## Validate mold structure (ailloy temper)
temper: deps
	@errors=0; \
	for m in $(MOLDS); do \
		if grep -q '^dependencies:' molds/$$m/mold.yaml; then \
			if [ -d molds/$$m/agents ]; then \
				echo "FAIL: molds/$$m declares dependencies AND ships an agents/ dir — a dependency-only aggregate must not ship its own content."; \
				errors=$$((errors+1)); \
				continue; \
			fi; \
			echo "==> skipping molds/$$m (dependency-only aggregate — resolves deps from published tags at release)"; \
			continue; \
		fi; \
		echo "==> ailloy temper molds/$$m"; \
		ailloy temper molds/$$m || errors=$$((errors+1)); \
	done; \
	if [ "$$errors" -gt 0 ]; then echo "FAIL: $$errors mold(s) failed validation."; exit 1; fi

## Lint AI instruction quality (ailloy assay)
assay: deps
	@errors=0; \
	for m in $(MOLDS); do \
		echo "==> ailloy assay molds/$$m"; \
		ailloy assay --fail-on error molds/$$m || errors=$$((errors+1)); \
	done; \
	if [ "$$errors" -gt 0 ]; then echo "FAIL: $$errors mold(s) failed AI lint."; exit 1; fi

## Check that all relative markdown links resolve to existing files
check-links:
	@python3 scripts/check-md-links.py .

## Install missing dev dependencies (ailloy)
deps:
	@if ! command -v ailloy >/dev/null 2>&1; then \
		echo "==> ailloy not found, installing $(AILLOY_VERSION)..."; \
		curl -fsSL https://raw.githubusercontent.com/nimble-giant/ailloy/main/install.sh | AILLOY_VERSION=$(AILLOY_VERSION) bash || \
			{ echo "FAIL: could not install ailloy. Install manually: https://github.com/nimble-giant/ailloy"; exit 1; }; \
	else \
		echo "==> ailloy: already installed"; \
	fi

## Test-cast every mold into a temp dir and verify success
cast-test: deps
	@errors=0; \
	for m in $(MOLDS); do \
		if grep -q '^dependencies:' molds/$$m/mold.yaml; then \
			if [ -d molds/$$m/agents ]; then \
				echo "FAIL: molds/$$m declares dependencies AND ships an agents/ dir — a dependency-only aggregate must not ship its own content."; \
				errors=$$((errors+1)); \
				continue; \
			fi; \
			echo "==> skipping molds/$$m (dependency-only aggregate — resolves deps from published tags at release)"; \
			continue; \
		fi; \
		dest=$$(mktemp -d); \
		echo "==> casting molds/$$m into $$dest"; \
		(cd "$$dest" && ailloy cast $(CURDIR)/molds/$$m 2>&1) | tail -1; \
		if [ $$? -ne 0 ]; then errors=$$((errors+1)); fi; \
		rm -rf "$$dest"; \
	done; \
	if [ "$$errors" -gt 0 ]; then echo "FAIL: $$errors mold(s) failed cast."; exit 1; \
	else echo "PASS: all molds cast successfully."; fi

## Show available targets
help:
	@grep -B1 -E '^[a-zA-Z0-9_-]+:' $(MAKEFILE_LIST) | grep -A1 '^##' | grep -E '^[a-zA-Z]' | sed 's/:.*//' | sort -u
