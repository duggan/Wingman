# Wingman — build, bundle, sign, and notarize a Developer-ID macOS app with an
# SMAppService privileged daemon. Needs only the Swift toolchain that ships with
# Xcode (plus an Apple ID for `make release`). GPL-3.0.

APP_NAME  := Wingman
APP_ID    := ie.duggan.Wingman
HELPER_ID := ie.duggan.Wingman.Helper
TEAM_ID   := PSPQTHW392

# Override if your identity string differs:
#   make sign SIGN_ID="Developer ID Application: Your Name (TEAMID)"
SIGN_ID ?= Developer ID Application: Ross Duggan (PSPQTHW392)

BUILD_CONFIG ?= release
ARCHFLAGS    ?= --arch arm64 --arch x86_64
APP_BUNDLE   := build/$(APP_NAME).app
CONTENTS     := $(APP_BUNDLE)/Contents
DMG          := build/$(APP_NAME).dmg
ZIP          := build/$(APP_NAME)-notarize.zip

# `xcrun notarytool store-credentials` keychain profile (see `make notary-setup`).
NOTARY_PROFILE ?= wingman

# Styled "drag to Applications" DMG layout (built with create-dmg).
DMG_STAGE := build/dmg-src
DMG_OPTS  := --volname "$(APP_NAME)" --background "Resources/dmg-background.png" \
             --window-pos 200 120 --window-size 660 420 --icon-size 120 \
             --icon "$(APP_NAME).app" 175 215 --hide-extension "$(APP_NAME).app" \
             --app-drop-link 485 215 --no-internet-enable

.PHONY: all build bundle sign run test dmg release notary-setup check-iso probe-iso fetch-iso clean help

all: sign ## Build, bundle, and sign (default)

build: ## Compile the universal (arm64+x86_64) binaries with SwiftPM
	swift build -c $(BUILD_CONFIG) $(ARCHFLAGS)

bundle: build ## Assemble the .app bundle from the built binaries
	@set -e; \
	BIN="$$(swift build -c $(BUILD_CONFIG) $(ARCHFLAGS) --show-bin-path)"; \
	echo "Using bin path: $$BIN"; \
	rm -rf "$(APP_BUNDLE)"; \
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Library/LaunchDaemons" "$(CONTENTS)/Resources"; \
	cp "$$BIN/$(APP_NAME)App" "$(CONTENTS)/MacOS/$(APP_NAME)"; \
	cp "$$BIN/$(APP_NAME)Helper" "$(CONTENTS)/MacOS/$(APP_NAME)Helper"; \
	cp Resources/App-Info.plist "$(CONTENTS)/Info.plist"; \
	cp Resources/Wingman.icns "$(CONTENTS)/Resources/Wingman.icns"; \
	cp Resources/wingman-logo.png "$(CONTENTS)/Resources/wingman-logo.png"; \
	cp Resources/Helper-Launchd.plist "$(CONTENTS)/Library/LaunchDaemons/$(HELPER_ID).plist"; \
	echo "Assembled $(APP_BUNDLE)"

sign: bundle ## Code-sign bottom-up (helper first, app last), Hardened Runtime
	codesign --force --options runtime --timestamp \
	  --sign "$(SIGN_ID)" --entitlements Resources/Helper.entitlements \
	  --identifier "$(HELPER_ID)" "$(CONTENTS)/MacOS/$(APP_NAME)Helper"
	codesign --force --options runtime --timestamp \
	  --sign "$(SIGN_ID)" --entitlements Resources/App.entitlements \
	  --identifier "$(APP_ID)" "$(APP_BUNDLE)"
	codesign --verify --strict --verbose=2 "$(APP_BUNDLE)"
	@echo "Signed & verified $(APP_BUNDLE)"

run: sign ## Sign then launch the app
	open "$(APP_BUNDLE)"

test: ## Run the WimKit unit tests (no ISO needed)
	swift test

check-iso: ## Check a Windows ISO is Wingman-compatible:  make check-iso ISO=/path/to/Win11.iso
	@test -n "$(ISO)" || { echo "usage: make check-iso ISO=/path/to/Win11.iso" >&2; exit 2; }
	@swift build --product WimTool >/dev/null
	@set -e; \
	BIN="$$(swift build --show-bin-path)"; \
	OUT="$$(hdiutil attach -nobrowse -readonly -noverify "$(ISO)")"; \
	MP="$$(echo "$$OUT" | grep -o '/Volumes/.*' | head -1)"; \
	DEV="$$(echo "$$OUT" | grep -oE '^/dev/disk[0-9]+' | head -1)"; \
	echo "Inspecting $$MP/sources/install.wim"; echo; \
	RC=0; "$$BIN/WimTool" "$$MP/sources/install.wim" || RC=$$?; \
	hdiutil detach "$$DEV" >/dev/null 2>&1 || true; \
	exit $$RC

probe-iso: ## Compatibility-check an ISO by reading ~5 MB — local path or URL: make probe-iso ISO=...
	@test -n "$(ISO)" || { echo "usage: make probe-iso ISO=<iso-path-or-url>" >&2; exit 2; }
	@swift build --product WimTool >/dev/null
	@"$$(swift build --show-bin-path)/WimTool" probe "$(ISO)"

fetch-iso: ## Download the latest Windows ISO + check it (FETCH_ARGS="--win 10"; needs `brew install powershell`)
	@bash tools/fetch-windows-iso/fetch-iso.sh --check $(FETCH_ARGS)

dmg: sign ## Build a signed (not-yet-notarized) styled DMG for local testing
	rm -f "$(DMG)"
	rm -rf "$(DMG_STAGE)" && mkdir -p "$(DMG_STAGE)"
	ditto "$(APP_BUNDLE)" "$(DMG_STAGE)/$(APP_NAME).app"
	create-dmg $(DMG_OPTS) "$(DMG)" "$(DMG_STAGE)" || true
	codesign --force --timestamp --sign "$(SIGN_ID)" "$(DMG)"
	@echo "Built styled $(DMG) (signed only; run 'make release' to notarize)"

release: sign ## Full notarized release: staple the .app, then build+notarize the DMG
	# 1. Notarize + staple the app, so it's valid offline once copied out of the DMG.
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(ZIP)"
	xcrun notarytool submit "$(ZIP)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP_BUNDLE)"
	rm -f "$(ZIP)"
	# 2. Build the styled DMG from the stapled app, then notarize + staple it.
	rm -f "$(DMG)"
	rm -rf "$(DMG_STAGE)" && mkdir -p "$(DMG_STAGE)"
	ditto "$(APP_BUNDLE)" "$(DMG_STAGE)/$(APP_NAME).app"
	create-dmg $(DMG_OPTS) "$(DMG)" "$(DMG_STAGE)" || true
	codesign --force --timestamp --sign "$(SIGN_ID)" "$(DMG)"
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	xcrun stapler validate "$(DMG)"
	@echo "Release ready (notarized + stapled): $(DMG)"

notary-setup: ## One-time: store an Apple ID app-specific password for notarytool
	@echo "Create an app-specific password at https://appleid.apple.com, then run once:"
	@echo ""
	@echo "  xcrun notarytool store-credentials $(NOTARY_PROFILE) \\"
	@echo "      --apple-id <your-apple-id> --team-id $(TEAM_ID) --password <app-specific-password>"
	@echo ""
	@echo "Afterwards, 'make release' notarizes without prompting."

clean: ## Remove build artifacts
	rm -rf .build build

help: ## List targets
	@grep -E '^[a-z][a-z-]*:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-13s %s\n", $$1, $$2}'
