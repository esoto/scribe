XCODEBUILD := xcodebuild -project native/Scribe.xcodeproj -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation

MODEL_LOG_DIR ?= dist/model-logs

# Regenerate the Xcode project after adding/removing source files.
generate:
	cd native && xcodegen generate

# Fast unit tests (no models, no hardware).
test:
	$(XCODEBUILD) -scheme ScribeTests test

# Real-model tests: golden cleanup eval, STT fixtures, memory reclaim.
test-models:
	$(XCODEBUILD) -scheme ScribeModelTests test

# Compile-check the real-model test target without running it (no GPU).
# `make test` builds only ScribeTests, so ScribeModelTests breakage is otherwise invisible.
build-models:
	$(XCODEBUILD) -scheme ScribeModelTests build-for-testing

# The classes that honour CLEANUP_MODEL (through cleanupBackendUnderTest()).
# FastPathBoundaryTests, GemmaPreloadTests, MemoryReclaimTests and
# DictionaryWarmRebuildTests hard-wire GemmaBackend() (Gemma 3), so they run
# ONLY under `make test-models`: including them here would keep a second model
# resident and contaminate the latency / RAM numbers.
CLEANUP_MODEL_TESTS := \
  -only-testing:ScribeModelTests/GoldenEvalTests \
  -only-testing:ScribeModelTests/InjectionGuardTests \
  -only-testing:ScribeModelTests/DictionaryGoldenEvalTests \
  -only-testing:ScribeModelTests/DictionaryFidelityTests

# $(1) = CLEANUP_MODEL id, $(2) = "ignore" to ignore xcodebuild's exit code.
# CLEANUP_MODEL must be an ENVIRONMENT variable (xcodebuild forwards
# TEST_RUNNER_-prefixed env vars into the test process); as an xcodebuild
# argument it is ignored — and cleanupSpecUnderTest() silently falls back to
# gemma3, so these targets FAIL unless the log contains this model's
# `golden[<id>]` tag (a dropped variable would otherwise "pass" on Gemma 3).
define run-cleanup-model-tests
	@mkdir -p $(MODEL_LOG_DIR)
	@set -o pipefail; \
	TEST_RUNNER_CLEANUP_MODEL=$(1) $(XCODEBUILD) -scheme ScribeModelTests $(CLEANUP_MODEL_TESTS) test 2>&1 | tee $(MODEL_LOG_DIR)/$(1).log; \
	rc=$$?; \
	grep -qF 'golden[$(1)]' $(MODEL_LOG_DIR)/$(1).log || { echo "ERROR: no golden[$(1)] output in the log - CLEANUP_MODEL did not reach the tests (or the suite was skipped)"; exit 1; }; \
	if [ "$(2)" = ignore ]; then echo "report-only: xcodebuild exit code $$rc ignored - read the logged table"; exit 0; fi; \
	exit $$rc
endef

# The Gemma models are held to the full gate (golden 10/10 + guard + fidelity)
# because one of them could become the default, so a red gate hard-fails here.
# test-models-afm is report-only: Apple Intelligence is opt-in and not held to
# 10/10 (it scores 8/10), so its xcodebuild exit code is ignored and the logged
# table is the result.
test-models-gemma4:
	$(call run-cleanup-model-tests,gemma4,)

test-models-e2b:
	$(call run-cleanup-model-tests,gemma4e2b,)

# Apple Intelligence: REPORT-ONLY — an opt-in model, not held to 10/10 (it has
# no known_failures and scores 8/10), so the golden/fidelity asserts WILL fail
# xcodebuild. The exit code is ignored; read the logged table. The tag check
# above still applies, so an unavailable/skipped run is an error, not a pass.
test-models-afm:
	$(call run-cleanup-model-tests,appleIntelligence,ignore)

# Report-only measurements (M-2, M-3 in docs/superpowers/plans/2026-10-22-1.5-features.md).
# They print numbers and assert almost nothing, so read the log. Like the cleanup targets, they
# FAIL when the expected tag is missing from the log: an XCTSkip (fixture absent) or a dropped
# TEST_RUNNER_CLEANUP_MODEL would otherwise "pass" with no numbers.
measure-longform:
	@mkdir -p $(MODEL_LOG_DIR)
	@set -o pipefail; \
	$(XCODEBUILD) -scheme ScribeModelTests -only-testing:ScribeModelTests/LongFormFixtureTests test 2>&1 | tee $(MODEL_LOG_DIR)/longform.log; \
	rc=$$?; \
	for tag in 'longform[en90]' 'longform[es90]'; do \
	  grep -qF "$$tag" $(MODEL_LOG_DIR)/longform.log || { echo "ERROR: no $$tag output in the log - fixture missing (skipped) or the suite did not run"; exit 1; }; \
	done; \
	exit $$rc

# One model per run: TEST_RUNNER_CLEANUP_MODEL=gemma4 make measure-cleanup-latency (default gemma3).
measure-cleanup-latency:
	@mkdir -p $(MODEL_LOG_DIR)
	@set -o pipefail; \
	model=$${TEST_RUNNER_CLEANUP_MODEL:-gemma3}; \
	$(XCODEBUILD) -scheme ScribeModelTests -only-testing:ScribeModelTests/CleanupLatencyByLengthTests test 2>&1 | tee $(MODEL_LOG_DIR)/latency-$$model.log; \
	rc=$$?; \
	grep -qF "latency[$$model]" $(MODEL_LOG_DIR)/latency-$$model.log || { echo "ERROR: no latency[$$model] output in the log - CLEANUP_MODEL did not reach the tests (or the suite was skipped)"; exit 1; }; \
	exit $$rc

# Package the native app: Release build -> dist/scribe-<version>.zip.
# `make install-app` additionally replaces /Applications/Scribe.app.
app:
	scripts/package_app.sh

install-app:
	scripts/package_app.sh --install
