.PHONY: build build-release run dev test fmt lint dmg xcodegen ghostty screenshot clean help

SCHEME  := Limpid
PROJECT := Limpid.xcodeproj
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
	@echo "  make fmt       Auto-format with SwiftFormat"
	@echo "  make lint      Lint (SwiftFormat lint + SwiftLint), mirrors CI"
	@echo "  make dmg       Package a release DMG"
	@echo "  make xcodegen  Regenerate Limpid.xcodeproj from project.yml"
	@echo "  make ghostty   Build vendored libghostty"
	@echo "  make screenshot Regenerate .github/assets/hero.png (demo mode)"
	@echo "  make clean     Remove DerivedData for this project"

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) build

build-release:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release build

run:
	@app="$(APP_PATH)"; \
	if [ ! -d "$$app" ]; then echo "App not found: $$app (run 'make build' first)"; exit 1; fi; \
	osascript -e 'tell application "Limpid Dev" to quit' >/dev/null 2>&1 || true; \
	open "$$app"

dev: build run

test:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' test

fmt:
	swiftformat .

lint:
	swiftformat --lint .
	swiftlint --quiet

dmg:
	./scripts/package-dmg.sh

xcodegen:
	xcodegen

ghostty:
	./scripts/build-ghostty.sh

screenshot: build-release
	./scripts/screenshot.sh

clean:
	rm -rf $(HOME)/Library/Developer/Xcode/DerivedData/Limpid-*
