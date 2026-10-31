.PHONY: build build-release release-check run dev test test-measure rust-test review-core fmt rust-fmt lint rust-lint rust-header dmg xcodegen ghostty screenshot clean help FORCE

SCHEME  := Weir
PROJECT := Weir.xcodeproj
PBXPROJ := $(PROJECT)/project.pbxproj
CONFIG  := Debug
BUILD_DESTINATION ?= generic/platform=macOS

# Debug is ad-hoc signed unless WEIR_DEVELOPMENT_TEAM names a Team ID. The
# approval service authenticates its peers by Team ID, so native approvals run
# only in a build signed this way; CONTRIBUTING.md has the setup.
WEIR_CODE_SIGN_IDENTITY ?= Apple Development
DEBUG_SIGNING = $(if $(WEIR_DEVELOPMENT_TEAM),CODE_SIGN_IDENTITY='$(WEIR_CODE_SIGN_IDENTITY)' DEVELOPMENT_TEAM='$(WEIR_DEVELOPMENT_TEAM)')
# An incremental build re-signs the helper tools but leaves the copies already
# embedded in the app untouched, so after a signer change the service rejects
# them. `build` and `test` share one signer, record it in DEBUG_SIGNING_STAMP,
# and remove the built app when it changes, so Xcode embeds and signs the
# tools again while compiled objects stay cached.
DEBUG_SIGNER = $(if $(WEIR_DEVELOPMENT_TEAM),$(WEIR_DEVELOPMENT_TEAM) $(WEIR_CODE_SIGN_IDENTITY),ad-hoc)
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
RELEASE_APP_PATH = $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{d=$$2} / FULL_PRODUCT_NAME = /{n=$$2} END{print d"/"n}')

help:
	@echo "Weir — common targets"
	@echo "  make build       Build Debug"
	@echo "  make run         Launch the built app"
	@echo "  make dev         build + run"
	@echo "  make test        Run the Rust and Swift Testing suites"
	@echo "  make test-measure Run the timing suite that make test leaves out"
	@echo "  make rust-test   Run Rust workspace tests"
	@echo "  make review-core Run the review scenarios without building the app"
	@echo "  make fmt         Auto-format with SwiftFormat"
	@echo "  make lint        Lint Swift and Rust sources, mirrors CI"
	@echo "  make rust-header Regenerate the bridge C header and fail if it drifted"
	@echo "  make release-check Archive Release unsigned and check it can be distributed"
	@echo "  make dmg         Package a release DMG"
	@echo "  make xcodegen    Regenerate Weir.xcodeproj from project.yml"
	@echo "  make ghostty     Build vendored libghostty"
	@echo "  make screenshot  Regenerate .github/assets/hero.png (demo mode)"
	@echo "  make clean       Remove DerivedData for this project"

# Regenerate the Xcode project when it is missing, when project.yml changed,
# or when a file under a source directory was added, removed, or renamed.
# xcodegen expands each source path into the files present when it runs and
# the project is not tracked, so a new file needs a regeneration the
# project.yml timestamp alone never triggers. The script decides from content
# rather than mtimes, because this make compares mtimes to the whole second.
# Anything that depends on `$(PBXPROJ)` picks up fresh xcodegen output, so
# `make build` lands either change without a manual `make xcodegen` step.
XCODEGEN_INPUTS := build/xcodegen.inputs
SOURCE_DIRS := Weir WeirTests AgentIntegrationService
REGENERATE_PROJECT = scripts/regenerate-project-if-stale.sh

$(PBXPROJ): FORCE
	@$(REGENERATE_PROJECT) $(PBXPROJ) $(XCODEGEN_INPUTS) project.yml $(SOURCE_DIRS)

FORCE:

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
# `exportArchive` depends on. RELEASE_CHECK_BUILD_SETTINGS adds build settings;
# left empty, the archive is optimized as a release is.
RELEASE_CHECK_ARCHIVE ?= build/ReleaseCheck/Weir.xcarchive
RELEASE_CHECK_BUILD_SETTINGS ?=
release-check: $(PBXPROJ)
	scripts/test-check-release-archive.sh
	rm -rf '$(RELEASE_CHECK_ARCHIVE)'
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination '$(BUILD_DESTINATION)' \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
		$(RELEASE_CHECK_BUILD_SETTINGS) \
		archive -archivePath '$(RELEASE_CHECK_ARCHIVE)'
	scripts/check-release-archive.sh '$(RELEASE_CHECK_ARCHIVE)'

run:
	@app="$(APP_PATH)"; \
	if [ ! -d "$$app" ]; then echo "App not found: $$app (run 'make build' first)"; exit 1; fi; \
	osascript -e 'tell application "Weir Dev" to quit' >/dev/null 2>&1 || true; \
	open "$$app"

dev: build run

test: rust-test $(PBXPROJ)
	$(debug_signing_guard)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' \
		$(DEBUG_SIGNING) test

# The timing tests print numbers for a person to compare and check none of
# them, so they are off unless asked for. The Rust measurements are the ignored
# tests, run in release because a debug figure says little about the app.
# xcodebuild hands a TEST_RUNNER_-prefixed variable to the test process without
# the prefix.
test-measure: $(PBXPROJ)
	$(debug_signing_guard)
	cargo test --locked --release --workspace -- --ignored --nocapture
	TEST_RUNNER_WEIR_MEASURE=1 xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' \
		$(DEBUG_SIGNING) -only-testing:WeirTests/ScrollingCostMeasurements \
		'-only-testing:WeirTests/TurnRecordCacheTests/aPassOverAThousandTurns_isTimed()' test

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
	scripts/check-localization.sh
	scripts/test-check-localization.sh
	scripts/test-screenshot-app.sh
	scripts/test-derive-expected-events.sh

# The bridge's build script writes the header from the exported Rust items, so
# a drifted commit shows up as a diff rather than as a Swift link failure.
rust-header:
	cargo build --locked --package weir-rust-bridge
	@git diff --exit-code -- rust/weir-rust-bridge/include/weir_rust_bridge.h \
		|| { echo "error: the generated header differs from the index; review the diff above and stage the header" >&2; exit 1; }

rust-lint: rust-fmt rust-header
	cargo clippy --locked --workspace --all-targets -- -D warnings

dmg:
	./scripts/package-dmg.sh

# Always regenerate: the explicit escape hatch for a project that drifted in
# a way the inputs above cannot see.
xcodegen:
	@$(REGENERATE_PROJECT) --force $(PBXPROJ) $(XCODEGEN_INPUTS) project.yml $(SOURCE_DIRS)

ghostty:
	./scripts/build-ghostty.sh

# Hand the script the Release app this project just built, so it never
# captures another worktree's newer build from DerivedData.
screenshot: build-release
	WEIR_SCREENSHOT_APP='$(RELEASE_APP_PATH)' ./scripts/screenshot.sh

clean:
	rm -rf $(HOME)/Library/Developer/Xcode/DerivedData/Weir-*
