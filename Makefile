.PHONY: build build-release release-check run dev test rust-test review-core fmt rust-fmt lint rust-lint rust-header dmg xcodegen ghostty screenshot clean help

SCHEME  := Limpid
PROJECT := Limpid.xcodeproj
PBXPROJ := $(PROJECT)/project.pbxproj
CONFIG  := Debug
BUILD_DESTINATION ?= generic/platform=macOS

# Debug is ad-hoc signed unless LIMPID_DEVELOPMENT_TEAM names a Team ID. The
# approval service authenticates its peers by Team ID, so native approvals run
# only in a build signed this way; CONTRIBUTING.md has the setup.
LIMPID_CODE_SIGN_IDENTITY ?= Apple Development
DEBUG_SIGNING = $(if $(LIMPID_DEVELOPMENT_TEAM),CODE_SIGN_IDENTITY='$(LIMPID_CODE_SIGN_IDENTITY)' DEVELOPMENT_TEAM='$(LIMPID_DEVELOPMENT_TEAM)')
# An incremental build re-signs the helper tools but leaves the copies already
# embedded in the app untouched, so after a signer change the service rejects
# them. `build` and `test` share one signer, record it in DEBUG_SIGNING_STAMP,
# and remove the built app when it changes, so Xcode embeds and signs the
# tools again while compiled objects stay cached.
DEBUG_SIGNER = $(if $(LIMPID_DEVELOPMENT_TEAM),$(LIMPID_DEVELOPMENT_TEAM) $(LIMPID_CODE_SIGN_IDENTITY),ad-hoc)
DEBUG_SIGNING_STAMP := build/debug-signing
define debug_signing_guard
@signer='$(DEBUG_SIGNER)'; \
	if [ "$$signer" != "$$(cat $(DEBUG_SIGNING_STAMP) 2>/dev/null || echo ad-hoc)" ]; then \
		app=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
			-showBuildSettings 2>/dev/null | awk -F' = ' \
			'/ BUILT_PRODUCTS_DIR = /{d=$$2} / FULL_PRODUCT_NAME = /{n=$$2} END{print d"/"n}'); \
		case "$$app" in \
			*/Build/Products/*.app) \
				echo "Debug signing changed; removing $$app"; rm -rf "$$app";; \
			*) echo "Debug signing changed, but the built app was not found: '$$app'" >&2; exit 1;; \
		esac; \
	fi; \
	mkdir -p $(dir $(DEBUG_SIGNING_STAMP)); printf '%s' "$$signer" > $(DEBUG_SIGNING_STAMP)
endef

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
	@echo "  make release-check Archive Release unsigned and check it can be distributed"
	@echo "  make dmg         Package a release DMG"
	@echo "  make xcodegen    Regenerate Limpid.xcodeproj from project.yml"
	@echo "  make ghostty     Build vendored libghostty"
	@echo "  make screenshot  Regenerate .github/assets/hero.png (demo mode)"
	@echo "  make clean       Remove DerivedData for this project"

# Regenerate the Xcode project when project.yml is newer (or .pbxproj
# is missing entirely). Anything that depends on `$(PBXPROJ)` picks up
# fresh xcodegen output automatically, so editing `project.yml` and
# running `make build` lands the change without a manual `make
# xcodegen` step. The `xcodegen` phony target stays for explicit
# invocation.
$(PBXPROJ): project.yml
	xcodegen

build: $(PBXPROJ)
	$(debug_signing_guard)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-destination '$(BUILD_DESTINATION)' $(DEBUG_SIGNING) build

build-release: $(PBXPROJ)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination '$(BUILD_DESTINATION)' build

# `build` alone never assembles an archive, which is how the v0.1.5 generic
# archive reached the release workflow. We archive unsigned so this runs
# without the Developer ID certificate, then check the layout that
# `exportArchive` depends on.
RELEASE_CHECK_ARCHIVE ?= build/ReleaseCheck/Limpid.xcarchive
release-check: $(PBXPROJ)
	scripts/test-check-release-archive.sh
	rm -rf '$(RELEASE_CHECK_ARCHIVE)'
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination '$(BUILD_DESTINATION)' \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
		archive -archivePath '$(RELEASE_CHECK_ARCHIVE)'
	scripts/check-release-archive.sh '$(RELEASE_CHECK_ARCHIVE)'

run:
	@app="$(APP_PATH)"; \
	if [ ! -d "$$app" ]; then echo "App not found: $$app (run 'make build' first)"; exit 1; fi; \
	osascript -e 'tell application "Limpid Dev" to quit' >/dev/null 2>&1 || true; \
	open "$$app"

dev: build run

test: rust-test $(PBXPROJ)
	$(debug_signing_guard)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' \
		$(DEBUG_SIGNING) test

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
