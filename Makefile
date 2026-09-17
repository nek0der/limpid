.PHONY: build build-release run dev test rust-test review-core fmt rust-fmt lint rust-lint rust-header dmg xcodegen ghostty screenshot clean clean-tmux help

SCHEME  := Limpid
PROJECT := Limpid.xcodeproj
PBXPROJ := $(PROJECT)/project.pbxproj
CONFIG  := Debug
BUILD_DESTINATION ?= generic/platform=macOS

# Resolve the built .app path from xcodebuild itself so we don't guess the
# DerivedData hash or the Dev/Release product name.
APP_PATH = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{d=$$2} / FULL_PRODUCT_NAME = /{n=$$2} END{print d"/"n}')

help:
	@echo "Limpid — common targets"
	@echo "  make build       Build Debug"
	@echo "  make run         Launch the built app"
	@echo "  make dev         build + run"
	@echo "  make test        Run XCTest / Swift Testing suites"
	@echo "  make rust-test   Run Rust workspace tests"
	@echo "  make review-core Run the review scenarios without building the app"
	@echo "  make fmt         Auto-format with SwiftFormat"
	@echo "  make lint        Lint Swift and Rust sources, mirrors CI"
	@echo "  make rust-header Regenerate the bridge C header and fail if it drifted"
	@echo "  make dmg         Package a release DMG"
	@echo "  make xcodegen    Regenerate Limpid.xcodeproj from project.yml"
	@echo "  make ghostty     Build vendored libghostty"
	@echo "  make screenshot  Regenerate .github/assets/hero.png (demo mode)"
	@echo "  make clean       Remove DerivedData for this project"
	@echo "  make clean-tmux  Kill the throwaway tmux servers a failed test run left"

# Regenerate the Xcode project when project.yml is newer (or .pbxproj
# is missing entirely). Anything that depends on `$(PBXPROJ)` picks up
# fresh xcodegen output automatically, so editing `project.yml` and
# running `make build` lands the change without a manual `make
# xcodegen` step. The `xcodegen` phony target stays for explicit
# invocation.
$(PBXPROJ): project.yml
	xcodegen

build: $(PBXPROJ)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-destination '$(BUILD_DESTINATION)' build

build-release: $(PBXPROJ)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination '$(BUILD_DESTINATION)' build

run:
	@app="$(APP_PATH)"; \
	if [ ! -d "$$app" ]; then echo "App not found: $$app (run 'make build' first)"; exit 1; fi; \
	osascript -e 'tell application "Limpid Dev" to quit' >/dev/null 2>&1 || true; \
	open "$$app"

dev: build run

test: rust-test $(PBXPROJ)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' test

rust-test:
	cargo test --locked --workspace --all-targets

# The terminal probe on its own, which is the one review scenario the test
# target cannot host: it spawns processes, and the parallel suites reuse the
# descriptor numbers another test asserts are closed.
review-core:
	scripts/validate-review-core.sh

fmt:
	cargo fmt --all
	mint run swiftformat .

rust-fmt:
	cargo fmt --all --check

lint: rust-lint
	mint run swiftformat --lint .
	swiftlint lint --strict

# The bridge's build script writes the header from the exported Rust items, so
# a drifted commit shows up as a diff rather than as a Swift link failure.
rust-header:
	cargo build --locked --package limpid-rust-bridge
	@git diff --exit-code -- rust/limpid-rust-bridge/include/limpid_rust_bridge.h \
		|| { echo "error: the generated header differs from the index; review the diff above and stage the header" >&2; exit 1; }

rust-lint: rust-fmt rust-header
	cargo clippy --locked --workspace --all-targets -- -D warnings

dmg:
	./scripts/package-dmg.sh

xcodegen: $(PBXPROJ)

ghostty:
	./scripts/build-ghostty.sh

screenshot: build-release
	./scripts/screenshot.sh

clean:
	rm -rf $(HOME)/Library/Developer/Xcode/DerivedData/Limpid-*

# A test run that is interrupted or crashes never reaches
# `TmuxServerFixture.tearDown`, leaving a tmux server on a socket under
# `$$TMPDIR/lt-*` and the directory with it. Each one holds a few processes
# and its own socket, so they accumulate across runs. Only the fixture's own
# directories are touched; the user's server lives elsewhere.
clean-tmux:
	@tmux=$$(command -v tmux || true); \
	tmpdir=$${TMPDIR:-/tmp}; \
	for dir in "$${tmpdir%/}"/lt-*; do \
		[ -d "$$dir" ] || continue; \
		if [ -n "$$tmux" ] && [ -S "$$dir/sock" ]; then \
			$$tmux -S "$$dir/sock" kill-server >/dev/null 2>&1 || true; \
		fi; \
		rm -rf "$$dir"; \
		echo "removed $$dir"; \
	done
