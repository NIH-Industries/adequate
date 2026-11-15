BUILT := tmp/DerivedData/Build/Products/Debug/Adequate.app
APP := $(HOME)/Applications/Adequate.app
CLI := tmp/bin/adequate
BIN ?= $(HOME)/.local/bin
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: build install run project cli install-cli

project:
	xcodegen generate --quiet

build: project cli
	xcodebuild -project Adequate.xcodeproj -scheme Adequate -configuration Debug \
	  -derivedDataPath tmp/DerivedData -quiet build

# Installs to ~/Applications, the one copy macOS should open links with.
# The build in tmp/ is unregistered so links never go to it.
install: build
	-osascript -e 'quit app "Adequate"'
	mkdir -p $(dir $(APP))
	rsync -a --delete $(BUILT)/ $(APP)/
	$(LSREGISTER) -u $(BUILT)
	$(LSREGISTER) -f $(APP)

run: install
	open $(APP)

cli: $(CLI)

$(CLI): AdequateCLI/main.swift
	mkdir -p tmp/bin
	swiftc -O AdequateCLI/main.swift -o $(CLI)

# Puts `adequate` on your PATH as a link to the freshly built CLI.
install-cli: cli
	mkdir -p $(BIN)
	ln -sf $(CURDIR)/$(CLI) $(BIN)/adequate
