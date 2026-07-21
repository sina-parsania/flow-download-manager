# Download Manager — stable validation interface (08-validation-commands.md).
# Underlying scripts may evolve without changing this developer-facing interface.

SHELL := /bin/bash
.DEFAULT_GOAL := help

PROJECT      := DownloadManager.xcodeproj
SCHEME       := DownloadManager
DESTINATION  := platform=macOS,arch=arm64
DERIVED      := .build/DerivedData
CONFIG_DEBUG := Debug
ARTIFACTS    := Artifacts/validation/latest
FIRST_PARTY  := Sources Tests Extensions Scripts .github Makefile project.yml

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	-destination '$(DESTINATION)' -derivedDataPath $(DERIVED)

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

## ----- Fast local gate -----

.PHONY: format-check
format-check: ## Verify formatting (no changes applied)
	@swiftformat --lint --config .swiftformat Sources Tests

.PHONY: format
format: ## Apply formatting
	@swiftformat --config .swiftformat Sources Tests

.PHONY: lint
lint: ## Lint + syntax-aware Swift safety scan
	@Scripts/lint.sh

.PHONY: build-debug
build-debug: project ## Clean-warning Debug build of app + embedded agent
	@mkdir -p $(ARTIFACTS)
	@set -o pipefail; $(XCODEBUILD) -configuration $(CONFIG_DEBUG) build \
		2>&1 | tee $(ARTIFACTS)/build.log

.PHONY: build-release
build-release: project ## Clean-warning Release build
	@set -o pipefail; $(XCODEBUILD) -configuration Release build

.PHONY: test-unit
test-unit: project ## Run unit tests
	@mkdir -p $(ARTIFACTS)
	@rm -rf $(ARTIFACTS)/unit-tests.xcresult
	@set -o pipefail; $(XCODEBUILD) \
		-only-testing:UnitTests \
		-resultBundlePath $(ARTIFACTS)/unit-tests.xcresult test 2>&1 | tail -40

.PHONY: incomplete-work-scan
incomplete-work-scan: ## Fail on banned incomplete-work / unsafe patterns in first-party code
	@Scripts/incomplete-work-scan.sh

.PHONY: verify-fast
verify-fast: format-check lint build-debug test-unit incomplete-work-scan ## Fast local gate
	@echo "verify-fast: OK"

## ----- Complete stable gate -----

.PHONY: test-integration
test-integration: project ## Integration tests
	@set -o pipefail; $(XCODEBUILD) -only-testing:IntegrationTests test 2>&1 | tail -40

.PHONY: test-recovery
test-recovery: project ## Recovery / crash-boundary tests
	@set -o pipefail; $(XCODEBUILD) -only-testing:RecoveryTests test 2>&1 | tail -40

.PHONY: test-ui
test-ui: project ## UI automation tests
	@set -o pipefail; $(XCODEBUILD) -only-testing:UITests test 2>&1 | tail -40

.PHONY: test-performance
test-performance: project ## Performance measurement tests
	@set -o pipefail; $(XCODEBUILD) -only-testing:PerformanceTests test 2>&1 | tail -40

.PHONY: test-fuzz
test-fuzz: project ## Property / enumerated / secure-coding tests
	@set -o pipefail; $(XCODEBUILD) \
		-only-testing:UnitTests/JobStateTransitionTests \
		-only-testing:UnitTests/SegmentStateTransitionTests \
		-only-testing:UnitTests/DomainValueTests \
		-only-testing:UnitTests/XPCCodingTests test 2>&1 | tail -40

.PHONY: analyze
analyze: project ## Clang/Swift static analyzer
	@set -o pipefail; $(XCODEBUILD) -configuration $(CONFIG_DEBUG) analyze 2>&1 | tail -40

# ASan and TSan run in separate passes (they are not combined — 05-quality §8).
# Sanitizers are enabled via xcodebuild flags rather than plan-internal target IDs
# (robust across project regeneration).
.PHONY: test-asan
test-asan: project ## Address Sanitizer pass (unit/integration/recovery)
	@set -o pipefail; $(XCODEBUILD) -enableAddressSanitizer YES \
		-only-testing:UnitTests -only-testing:IntegrationTests -only-testing:RecoveryTests \
		test 2>&1 | tail -40

.PHONY: test-tsan
test-tsan: project ## Thread Sanitizer pass (unit/integration/recovery)
	@set -o pipefail; $(XCODEBUILD) -enableThreadSanitizer YES \
		-only-testing:UnitTests -only-testing:IntegrationTests -only-testing:RecoveryTests \
		test 2>&1 | tail -40

.PHONY: test-accessibility
test-accessibility: project ## Accessibility UI audit (interactive lane)
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
db-migration-test: project ## Migration v1 round-trip tests
	@set -o pipefail; $(XCODEBUILD) -only-testing:UnitTests/MigrationTests test 2>&1 | tail -40

.PHONY: db-integrity-test
db-integrity-test: project ## Database integrity tests
	@set -o pipefail; $(XCODEBUILD) -only-testing:UnitTests/DatabaseIntegrityTests test 2>&1 | tail -40

.PHONY: recovery-crash-matrix
recovery-crash-matrix: project ## Crash-boundary reconciliation matrix
	@set -o pipefail; $(XCODEBUILD) -only-testing:RecoveryTests test 2>&1 | tail -40

## ----- Performance -----

.PHONY: performance-baseline
performance-baseline: project ## Record a performance baseline
	@Scripts/performance-baseline.sh

## ----- Housekeeping -----

.PHONY: clean
clean: ## Remove build products and evidence scratch
	@rm -rf $(DERIVED) Artifacts/validation/latest
	@echo "cleaned"
