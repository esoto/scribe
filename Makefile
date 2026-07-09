XCODEBUILD := xcodebuild -project native/Scribe.xcodeproj -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation

# Regenerate the Xcode project after adding/removing source files.
generate:
	cd native && xcodegen generate

# Fast unit tests (no models, no hardware).
test:
	$(XCODEBUILD) -scheme ScribeTests test

# Real-model tests: golden cleanup eval, STT fixtures, memory reclaim.
test-models:
	$(XCODEBUILD) -scheme ScribeModelTests test

# Package the native app: Release build -> dist/scribe-<version>.zip.
# `make install-app` additionally replaces /Applications/Scribe.app.
app:
	scripts/package_app.sh

install-app:
	scripts/package_app.sh --install
