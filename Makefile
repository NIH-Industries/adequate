# Everyday builds are Adequate Dev (its own bundle id, icon and data), so they
# sit beside the released Adequate rather than replacing it.
BUILT := tmp/DerivedData/Build/Products/Debug/Adequate Dev.app
APP ?= /Applications/Adequate Dev.app
DEV_ID := com.nih-industries.adequate.dev
CLI := tmp/bin/adequate
BIN ?= $(HOME)/.local/bin
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Release: a universal build signed with your Developer ID, notarised by
# Apple and stapled, so it opens on any Mac without Gatekeeper complaining.
# Needs the Developer ID Application certificate in your keychain and
# notarytool credentials saved as the `notary` profile
# (xcrun notarytool store-credentials notary).
VERSION := $(shell sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
IDENTITY ?= Developer ID Application
NOTARY ?= notary
RELEASE := tmp/release
RELEASE_APP := $(RELEASE)/Adequate.app
RELEASE_ZIP := $(RELEASE)/Adequate-$(VERSION).zip

# Everyday builds are signed with your Developer ID when it's in your
# keychain, so each rebuild is the same app to macOS and your permissions
# stick. Without one they're signed ad-hoc, which needs no Apple account.
SIGN := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"$(IDENTITY)' && echo "$(IDENTITY)" || echo -)

.PHONY: build install run project cli install-cli release

project:
	xcodegen generate --quiet

build: project cli
	xcodebuild -project Adequate.xcodeproj -scheme Adequate -configuration Debug \
	  -derivedDataPath tmp/DerivedData -quiet build
	codesign --force --sign "$(SIGN)" --options runtime --entitlements Adequate/Adequate.entitlements "$(BUILT)"

# Installs Adequate Dev to /Applications, beside the released Adequate (quitting
# only the dev copy). The build in tmp/ is unregistered so links never go to it.
install: build
	-osascript -e 'quit app id "$(DEV_ID)"'
	rsync -a --delete "$(BUILT)/" "$(APP)/"
	-$(LSREGISTER) -u "$(BUILT)" 2>/dev/null
	$(LSREGISTER) -f "$(APP)"

run: install
	open "$(APP)"

cli: $(CLI)

$(CLI): AdequateCLI/main.swift
	mkdir -p tmp/bin
	swiftc -O AdequateCLI/main.swift -o $(CLI)

# Puts `adequate` on your PATH as a link to the freshly built CLI.
install-cli: cli
	mkdir -p $(BIN)
	ln -sf $(CURDIR)/$(CLI) $(BIN)/adequate

# The CLI rides inside the app (Contents/Helpers/adequate) so the cask can
# put it on your PATH. Each piece is signed inside out: CLI, then the app.
release: project
	rm -rf $(RELEASE)
	xcodebuild -project Adequate.xcodeproj -scheme Adequate -configuration Release \
	  -derivedDataPath $(RELEASE)/DerivedData -destination 'generic/platform=macOS' \
	  -quiet build
	ditto $(RELEASE)/DerivedData/Build/Products/Release/Adequate.app $(RELEASE_APP)
	swiftc -O -target arm64-apple-macos15.0 AdequateCLI/main.swift -o $(RELEASE)/adequate-arm64
	swiftc -O -target x86_64-apple-macos15.0 AdequateCLI/main.swift -o $(RELEASE)/adequate-x86_64
	mkdir -p $(RELEASE_APP)/Contents/Helpers
	lipo -create $(RELEASE)/adequate-arm64 $(RELEASE)/adequate-x86_64 \
	  -output $(RELEASE_APP)/Contents/Helpers/adequate
	codesign --force --timestamp --options runtime --sign "$(IDENTITY)" \
	  --identifier com.nih-industries.adequate.cli $(RELEASE_APP)/Contents/Helpers/adequate
	codesign --force --timestamp --options runtime --sign "$(IDENTITY)" \
	  --entitlements Adequate/Adequate.entitlements $(RELEASE_APP)
	codesign --verify --strict --deep $(RELEASE_APP)
	ditto -c -k --keepParent $(RELEASE_APP) $(RELEASE)/notarise.zip
	xcrun notarytool submit $(RELEASE)/notarise.zip --keychain-profile $(NOTARY) --wait
	xcrun stapler staple $(RELEASE_APP)
	spctl --assess --type execute --verbose $(RELEASE_APP)
	ditto -c -k --keepParent $(RELEASE_APP) $(RELEASE_ZIP)
	@shasum -a 256 $(RELEASE_ZIP)
