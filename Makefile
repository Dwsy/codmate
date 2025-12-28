.PHONY: help build release test app dmg zip clean run notices

APP_NAME := CodMate
VER ?= 0.1.0
BUILD_NUMBER_STRATEGY ?= date
APP_DIR ?= build/CodMate.app
OUTPUT_DIR ?= artifacts/release

# Default arch for local builds
ARCH_NATIVE := $(shell uname -m)
ARCH ?= $(ARCH_NATIVE)

help: ## Show this help message
	@echo "CodMate - macOS SwiftPM App"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## SwiftPM debug build
	@swift build

release: ## SwiftPM release build
	@swift build -c release

test: ## Run SwiftPM tests (if any)
	@swift test

notices: ## Update THIRD-PARTY-NOTICES.md
	@python3 scripts/gen-third-party-notices.py

app: ## Build CodMate.app (ARCH=arm64|x86_64|"arm64 x86_64")
	@if [ -z "$(VER)" ]; then echo "error: VER is required (e.g., VER=1.2.3)"; exit 1; fi
	@VER=$(VER) BUILD_NUMBER_STRATEGY=$(BUILD_NUMBER_STRATEGY) \
	ARCH_MATRIX="$(ARCH)" APP_DIR=$(APP_DIR) \
	./scripts/create-app-bundle.sh

run: ## Build and launch CodMate.app (native arch, inferred version)
	@VER_RUN=$${VER:-$$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0.0)}; \
	ARCH_NATIVE=$$(uname -m); \
	VER="$$VER_RUN" BUILD_NUMBER_STRATEGY=$(BUILD_NUMBER_STRATEGY) \
	ARCH_MATRIX="$$ARCH_NATIVE" APP_DIR=$(APP_DIR) STRIP=0 SWIFT_CONFIG=debug \
	SIGN_ADHOC=1 \
	./scripts/create-app-bundle.sh; \
	open "$(APP_DIR)"

dmg: ## Build Developer ID DMG (ARCH=arm64|x86_64|"arm64 x86_64")
	@if [ -z "$(VER)" ]; then echo "error: VER is required (e.g., VER=1.2.3)"; exit 1; fi
	@VER=$(VER) BUILD_NUMBER_STRATEGY=$(BUILD_NUMBER_STRATEGY) \
	ARCH_MATRIX="$(ARCH)" APP_DIR=$(APP_DIR) OUTPUT_DIR=$(OUTPUT_DIR) \
	./scripts/macos-build-notarized-dmg.sh

zip: ## Create zip archives from DMG files (one zip per arch, requires dmg first, VER=1.2.3)
	@if [ -z "$(VER)" ]; then echo "error: VER is required (e.g., VER=1.2.3)"; exit 1; fi
	@if [ ! -d "$(OUTPUT_DIR)" ]; then echo "error: OUTPUT_DIR $(OUTPUT_DIR) does not exist. Run 'make dmg' first."; exit 1; fi
	@DMG_FILES=$$(find "$(OUTPUT_DIR)" -name "codmate-*.dmg" 2>/dev/null | sort); \
	if [ -z "$$DMG_FILES" ]; then \
		echo "error: No DMG files found in $(OUTPUT_DIR). Run 'make dmg' first."; \
		exit 1; \
	fi; \
	echo "Creating zip archives from DMG files..."; \
	cd "$(OUTPUT_DIR)" && \
	for dmg_file in $$DMG_FILES; do \
		dmg_basename=$$(basename "$$dmg_file" .dmg); \
		zip_name="$$dmg_basename.zip"; \
		echo "  Creating: $$zip_name"; \
		zip -q "$$zip_name" "$$dmg_basename.dmg"; \
	done; \
	echo "Zip archives created in $(OUTPUT_DIR)"

clean: ## Clean build artifacts
	@rm -rf .build build $(APP_DIR) artifacts
