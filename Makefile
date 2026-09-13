.PHONY: build build-release run dev test rust-test review-core fmt rust-fmt lint rust-lint dmg xcodegen ghostty screenshot clean help

SCHEME  := Limpid
PROJECT := Limpid.xcodeproj
PBXPROJ := $(PROJECT)/project.pbxproj
CONFIG  := Debug

# Resolve the built .app path from xcodebuild itself so we don't guess the
# DerivedData hash or the Dev/Release product name.
APP_PATH = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{d=$$2} / FULL_PRODUCT_NAME = /{n=$$2} END{print d"/"n}')

help:
	@echo "Limpid — common targets"
	@echo "  make build     Build Debug"
	@echo "  make run       Launch the built app"
	@echo "  make dev       build + run"
	@echo "  make test      Run XCTest / Swift Testing suites"
	@echo "  make rust-test Run Rust workspace tests"
	@echo "  make review-core  Run the review scenarios without building the app"
	@echo "  make fmt       Auto-format with SwiftFormat"
	@echo "  make lint      Lint Swift and Rust sources, mirrors CI"
	@echo "  make dmg       Package a release DMG"
	@echo "  make xcodegen  Regenerate Limpid.xcodeproj from project.yml"
	@echo "  make ghostty   Build vendored libghostty"
	@echo "  make screenshot Regenerate .github/assets/hero.png (demo mode)"
	@echo "  make clean     Remove DerivedData for this project"

# Regenerate the Xcode project when project.yml is newer (or .pbxproj
# is missing entirely). Anything that depends on `$(PBXPROJ)` picks up
# fresh xcodegen output automatically, so editing `project.yml` and
# running `make build` lands the change without a manual `make
# xcodegen` step. The `xcodegen` phony target stays for explicit
# invocation.
$(PBXPROJ): project.yml
	xcodegen

build: $(PBXPROJ)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) build

build-release: $(PBXPROJ)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release build

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

rust-lint: rust-fmt
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
