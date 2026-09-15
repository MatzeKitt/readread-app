PROJECT := ReadRead.xcodeproj
SCHEME  := ReadRead
PACKAGE := Packages/ReadReadKit
IOS_DEST := platform=iOS Simulator,name=iPhone 17 Pro
MAC_DEST := platform=macOS,arch=arm64

.DEFAULT_GOAL := help

.PHONY: help
help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: generate
generate: ## Regenerate the Xcode project from project.yml
	xcodegen generate

$(PROJECT): project.yml
	xcodegen generate

.PHONY: test
test: ## Run the package tests (no simulator needed)
	swift test --package-path $(PACKAGE)

.PHONY: build-mac
build-mac: $(PROJECT) ## Build the macOS app
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(MAC_DEST)' -configuration Debug build

.PHONY: build-ios
build-ios: $(PROJECT) ## Build for the iOS Simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(IOS_DEST)' -configuration Debug build

.PHONY: run-mac
run-mac: build-mac ## Build and launch the macOS app
	@open "$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(MAC_DEST)' -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/$(SCHEME).app"

.PHONY: check
check: test build-mac build-ios ## Everything CI would run

.PHONY: server-dev
server-dev: ## Serve the sync endpoint locally on :8787
	php -S 127.0.0.1:8787 -t server/public

.PHONY: server-test
server-test: ## Run the sync endpoint's smoke tests
	./server/tests/smoke.sh

.PHONY: clean
clean: ## Remove build products and the generated project
	rm -rf $(PROJECT) .build $(PACKAGE)/.build
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean 2>/dev/null || true
