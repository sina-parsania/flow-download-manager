# Download Manager — stable validation interface (08-validation-commands.md).
# Underlying scripts may evolve without changing this developer-facing interface.

SHELL := /bin/bash
.DEFAULT_GOAL := help

PROJECT      := DownloadManager.xcodeproj
SCHEME       := DownloadManager
DESTINATION  := platform=macOS,arch=arm64
# Overridable so a release can build in its own tree. Sharing one DerivedData
# with a long-running tool (an editor's build server, xcodebuildmcp) makes
# xctest fail to load a bundle that is present and correctly signed — see
# Scripts/release/publish.sh.
DERIVED      ?= .build/DerivedData
CONFIG_DEBUG := Debug
ARTIFACTS    := Artifacts/validation/latest
FIRST_PARTY  := Sources Tests BrowserExtension Scripts .github Makefile project.yml
# Prefer repo-pinned tooling from `make bootstrap-tools` over a floating Homebrew
# / image-preinstalled SwiftFormat (runners currently ship 0.62.x). format-check
# and format deliberately call Scripts/run-swiftformat.sh so they never PATH-fall
# through to the wrong binary.
export PATH := $(CURDIR)/Tools/bin:$(PATH)

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	-destination '$(DESTINATION)' -derivedDataPath '$(DERIVED)'

# Warnings-as-errors is enforced PER FIRST-PARTY TARGET via Configuration/Shared.xcconfig
# (SWIFT_TREAT_WARNINGS_AS_ERRORS / GCC_TREAT_WARNINGS_AS_ERRORS). It is deliberately NOT
# passed on the xcodebuild command line: a global override also hits vendor SPM targets
# (e.g. GRDB builds with -suppress-warnings) and yields a hard
# "conflicting options '-warnings-as-errors' and '-suppress-warnings'" driver error.
# Vendor sources are excluded from the warnings gate by policy (05-quality §6).
# See Documentation/adr/0002-warnings-as-errors-scope.md.

.PHONY: help
help: ## List available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2}'

## ----- Environment -----

.PHONY: doctor
doctor: ## Print toolchain report; fail on Intel/unsupported toolchain
	@Scripts/doctor.sh

.PHONY: bootstrap-tools
bootstrap-tools: ## Install pinned developer tools (xcodegen, swiftformat, swiftlint)
	@Scripts/bootstrap-tools.sh

.PHONY: project
project: ## Regenerate DownloadManager.xcodeproj from project.yml
	@xcodegen generate
	@echo "generated $(PROJECT) from project.yml"

.PHONY: resolve-dependencies
resolve-dependencies: project ## Resolve pinned Swift package dependencies
	@$(XCODEBUILD) -resolvePackageDependencies

.PHONY: dependency-manifest
dependency-manifest: ## Regenerate the resolved dependency/license manifest
	@Scripts/dependency-manifest.sh

.PHONY: vendor-libcurl
vendor-libcurl: ## Build pinned static arm64 libcurl stack into VendorBuild/prefix
	@VendorBuild/scripts/build-libcurl.sh

.PHONY: native-dependencies
native-dependencies: vendor-libcurl ## Pinned native stack required by DownloadKit-linked targets

## ----- Fast local gate -----

.PHONY: format-check
format-check: ## Verify formatting (no changes applied)
	@Scripts/run-swiftformat.sh --lint Sources Tests

.PHONY: format
format: ## Apply formatting
	@Scripts/run-swiftformat.sh --format Sources Tests

.PHONY: lint
lint: ## Lint + syntax-aware Swift safety scan
	@Scripts/lint.sh

.PHONY: build-debug
build-debug: native-dependencies project ## Clean-warning Debug build of app + embedded agent
	@mkdir -p $(ARTIFACTS)
	@set -o pipefail; $(XCODEBUILD) -configuration $(CONFIG_DEBUG) build \
		2>&1 | tee $(ARTIFACTS)/build.log

.PHONY: build-release
build-release: native-dependencies project ## Clean-warning Release build
	@set -o pipefail; $(XCODEBUILD) -configuration Release build

.PHONY: test-unit
test-unit: native-dependencies project ## Run unit tests
	@mkdir -p $(ARTIFACTS)
	@rm -rf $(ARTIFACTS)/unit-tests.xcresult $(ARTIFACTS)/unit-tests.log
	@set -o pipefail; \
	  if ! $(XCODEBUILD) -only-testing:UnitTests build-for-testing \
	    >$(ARTIFACTS)/unit-tests.log 2>&1; then \
	    echo "unit tests FAILED — build-for-testing:"; \
	    tail -40 $(ARTIFACTS)/unit-tests.log; \
	    exit 1; \
	  fi
	@set -o pipefail; \
	  if ! $(XCODEBUILD) \
	    -only-testing:UnitTests \
	    -resultBundlePath $(ARTIFACTS)/unit-tests.xcresult test-without-building \
	    >>$(ARTIFACTS)/unit-tests.log 2>&1; then \
	    echo "unit tests FAILED — failing cases:"; \
	    grep -E "Test Case .* failed|failed \(|XCTAssert|error:" $(ARTIFACTS)/unit-tests.log \
	      | grep -vE "Compiling |Linking |note: |warning: " | tail -120 || true; \
	    echo "---- last 40 lines ----"; \
	    tail -40 $(ARTIFACTS)/unit-tests.log; \
	    exit 1; \
	  fi; \
	  tail -20 $(ARTIFACTS)/unit-tests.log

.PHONY: incomplete-work-scan
incomplete-work-scan: ## Fail on banned incomplete-work / unsafe patterns in first-party code
	@Scripts/incomplete-work-scan.sh

.PHONY: verify-fast
verify-fast: format-check lint build-debug test-unit incomplete-work-scan ## Fast local gate
	@echo "verify-fast: OK"

## ----- Release tooling (local) -----

.PHONY: performance-baseline
performance-baseline: project ## Record immutable candidate performance descriptor
	@Scripts/performance-baseline.sh

.PHONY: performance-compare
performance-compare: ## Compare CANDIDATE against BASELINE=… (>10% regression fails)
	@Scripts/performance-compare.sh

.PHONY: release-sbom
release-sbom: ## Write dependency inventory under Artifacts/release/
	@Scripts/release/generate-sbom.sh

.PHONY: release-dmg-unsigned
release-dmg-unsigned: ## Build unsigned Release DMG (no signing/notarization)
	@Scripts/release/build-dmg.sh

.PHONY: release
release: ## Full release: gate, build, tag, publish, appcast. VERSION=X.Y.Z (DRY_RUN=1 to rehearse)
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=0.4.1 [DRY_RUN=1]"; exit 2; }
# Invoked through `bash`, not by its shebang, on purpose. A shebang-started
# script's executable image is the script file itself; when that file is on a
# removable volume macOS withholds removable-volume access from the process, and
# xctest cannot read the test bundles the gate is trying to run. See the header
# of Scripts/release/publish.sh.
	@bash Scripts/release/publish.sh $(VERSION)

.PHONY: release-appcast
release-appcast: ## Regenerate docs/appcast.xml from ONE staged zip (DIR=…)
	@test -n "$(DIR)" || { echo "usage: make release-appcast DIR=/path/with/one/zip"; exit 2; }
	@Scripts/release/sparkle-appcast.sh $(DIR)

.PHONY: install-release
install-release: ## Install latest (or TAG=vX.Y.Z) GitHub Release via Scripts/install.sh
	@Scripts/install.sh $(if $(TAG),--tag $(TAG),) $(INSTALL_FLAGS)

.PHONY: release-codesign
release-codesign: ## Codesign an .app (BLOCKED without DM_CODESIGN_IDENTITY)
	@Scripts/release/codesign.sh $(APP)

.PHONY: release-notarize
release-notarize: ## Notarize a signed DMG (BLOCKED without credentials)
	@Scripts/release/notarize.sh $(DMG)

.PHONY: install-chrome-native-host
install-chrome-native-host: ## Register the Chrome Native Messaging host (extension ID is derived; DM_CHROME_EXTENSION_ID overrides)
	@Scripts/install-chrome-native-host.sh

.PHONY: install-firefox-native-host
install-firefox-native-host: ## Register the Firefox Native Messaging host (ID read from the firefox manifest; DM_FIREFOX_EXTENSION_ID overrides)
	@Scripts/install-firefox-native-host.sh

# Firefox ships the same background/popup source as Chrome — only the manifest
# differs — so the loadable directory is staged rather than kept as a second
# copy that would drift out of sync with the cookie validation in background.js.
.PHONY: browser-extension-firefox
browser-extension-firefox: ## Stage the Firefox companion into .build/firefox-extension
	@rm -rf .build/firefox-extension
	@mkdir -p .build/firefox-extension
	@cp BrowserExtension/chrome/background.js BrowserExtension/chrome/popup.js \
		BrowserExtension/chrome/popup.html .build/firefox-extension/
	@cp -R BrowserExtension/chrome/icons .build/firefox-extension/icons
	@cp BrowserExtension/firefox/manifest.json .build/firefox-extension/manifest.json
	@echo "staged .build/firefox-extension (load via about:debugging)"

.PHONY: vendor-media-helpers
vendor-media-helpers: ## Fetch yt-dlp/ffmpeg when manifests include URL+sha256
	@Scripts/VendorBuild/fetch-media-helpers.sh

## ----- Complete stable gate -----

.PHONY: test-integration
test-integration: native-dependencies project ## Integration tests
	@set -o pipefail; $(XCODEBUILD) -only-testing:IntegrationTests build-for-testing 2>&1 | tail -20
	@set -o pipefail; $(XCODEBUILD) -only-testing:IntegrationTests test-without-building 2>&1 | tail -40

.PHONY: test-recovery
test-recovery: native-dependencies project ## Recovery / crash-boundary tests
	@set -o pipefail; $(XCODEBUILD) -only-testing:RecoveryTests build-for-testing 2>&1 | tail -20
	@set -o pipefail; $(XCODEBUILD) -only-testing:RecoveryTests test-without-building 2>&1 | tail -40

.PHONY: test-ui
test-ui: native-dependencies project ## UI automation tests
	@set -o pipefail; $(XCODEBUILD) -only-testing:UITests test 2>&1 | tail -40

.PHONY: test-performance
test-performance: native-dependencies project ## Performance measurement tests
	@set -o pipefail; $(XCODEBUILD) -only-testing:PerformanceTests test 2>&1 | tail -40

.PHONY: test-fuzz
test-fuzz: native-dependencies project ## Property / enumerated / secure-coding tests
	@set -o pipefail; $(XCODEBUILD) \
		-only-testing:UnitTests/JobStateTransitionTests \
		-only-testing:UnitTests/SegmentStateTransitionTests \
		-only-testing:UnitTests/DomainValueTests \
		-only-testing:UnitTests/XPCCodingTests test 2>&1 | tail -40

.PHONY: analyze
analyze: native-dependencies project ## Clang/Swift static analyzer
	@set -o pipefail; $(XCODEBUILD) -configuration $(CONFIG_DEBUG) analyze 2>&1 | tail -40

# ASan and TSan run in separate passes (they are not combined — 05-quality §8).
# Sanitizers are enabled via xcodebuild flags rather than plan-internal target IDs
# (robust across project regeneration).
.PHONY: test-asan
test-asan: native-dependencies project ## Address Sanitizer pass (unit/integration/recovery)
	@set -o pipefail; $(XCODEBUILD) -enableAddressSanitizer YES \
		-only-testing:UnitTests -only-testing:IntegrationTests -only-testing:RecoveryTests \
		test 2>&1 | tail -40

.PHONY: test-tsan
test-tsan: native-dependencies project ## Thread Sanitizer pass (unit/integration/recovery)
	@set -o pipefail; $(XCODEBUILD) -enableThreadSanitizer YES \
		-only-testing:UnitTests -only-testing:IntegrationTests -only-testing:RecoveryTests \
		test 2>&1 | tail -40

.PHONY: test-accessibility
test-accessibility: native-dependencies project ## Accessibility UI audit (interactive lane)
	@set -o pipefail; $(XCODEBUILD) -only-testing:UITests test 2>&1 | tail -40

.PHONY: audit-dependencies
audit-dependencies: ## Verify resolved dependency manifest matches pins
	@Scripts/audit-dependencies.sh

.PHONY: verify
verify: verify-fast test-integration test-recovery test-performance analyze test-asan test-tsan test-fuzz audit-dependencies ## Full stable gate + evidence bundle
	@Scripts/collect-evidence.sh
	@echo "verify: OK"

## ----- Deterministic test services -----

.PHONY: test-services-up test-services-health test-services-reset test-services-down
test-services-up: ## Start loopback fault services
	@Scripts/test-services.sh up
test-services-health: ## Report fault-service health
	@Scripts/test-services.sh health
test-services-reset: ## Reset fault-service state
	@Scripts/test-services.sh reset
test-services-down: ## Stop fault services
	@Scripts/test-services.sh down

## ----- Database / recovery -----

.PHONY: db-migration-test
db-migration-test: native-dependencies project ## Migration v1 round-trip tests
	@set -o pipefail; $(XCODEBUILD) -only-testing:UnitTests/MigrationTests test 2>&1 | tail -40

.PHONY: db-integrity-test
db-integrity-test: native-dependencies project ## Database integrity tests
	@set -o pipefail; $(XCODEBUILD) -only-testing:UnitTests/DatabaseIntegrityTests test 2>&1 | tail -40

.PHONY: recovery-crash-matrix
recovery-crash-matrix: native-dependencies project ## Crash-boundary reconciliation matrix
	@set -o pipefail; $(XCODEBUILD) -only-testing:RecoveryTests test 2>&1 | tail -40

## ----- Housekeeping -----

.PHONY: clean
clean: ## Remove build products and evidence scratch
	@rm -rf '$(DERIVED)' Artifacts/validation/latest
	@echo "cleaned"
