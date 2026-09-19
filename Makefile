# Blip build: SPM executable -> .app bundle -> codesign -> run.
#
# Two rules here are load-bearing and must not be "simplified":
#
#   1. APP_DIR is a FIXED path. TCC (Accessibility / Screen Recording) keys grants on
#      bundle path as well as signature, so building somewhere else means re-granting
#      permissions by hand every time.
#   2. SIGN_ID is a real Apple Development identity, never ad-hoc ("-"). An ad-hoc
#      signature makes TCC key the grant to the binary's cdhash, which changes on every
#      single build, so permissions silently vanish after each rebuild.

APP_NAME    := Blip
BUNDLE_ID   := com.mattiapuppo.blip
CONFIG      := debug
BUILD_DIR   := $(CURDIR)/build
APP_DIR     := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS    := $(APP_DIR)/Contents
BIN_DIR     := $(CONTENTS)/MacOS
RES_DIR     := $(CONTENTS)/Resources
SIGN_ID     := Apple Development: Mattia Puppo (2KGU59TDSE)
SWIFT_BIN   := $(CURDIR)/.build/$(CONFIG)/$(APP_NAME)

.PHONY: all build bundle sign run stop clean test probe identity icon

all: sign

build:
	swift build -c $(CONFIG)

# Regenerates AppIcon.icns from logo.png. Checked in, so a normal build does not need
# to run it; re-run after changing the artwork.
icon:
	@rm -rf "$(BUILD_DIR)/AppIcon.iconset" "$(BUILD_DIR)/logo-alpha.png"
	@mkdir -p "$(BUILD_DIR)/AppIcon.iconset"
	@swift "$(CURDIR)/Tools/make-icon.swift" "$(CURDIR)/logo.png" "$(BUILD_DIR)/logo-alpha.png"
	@for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x \
	             256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do \
		px=$${spec%%:*}; name=$${spec##*:}; \
		sips -z $$px $$px "$(BUILD_DIR)/logo-alpha.png" \
			--out "$(BUILD_DIR)/AppIcon.iconset/icon_$$name.png" >/dev/null; \
	done
	@iconutil -c icns "$(BUILD_DIR)/AppIcon.iconset" -o "$(CURDIR)/Resources/AppIcon.icns"
	@echo "icon -> Resources/AppIcon.icns"

bundle: build
	@rm -rf "$(APP_DIR)"
	@mkdir -p "$(BIN_DIR)" "$(RES_DIR)"
	@cp "$(SWIFT_BIN)" "$(BIN_DIR)/$(APP_NAME)"
	@cp "$(CURDIR)/Resources/Info.plist" "$(CONTENTS)/Info.plist"
	@cp "$(CURDIR)/Resources/AppIcon.icns" "$(RES_DIR)/AppIcon.icns"
	@cp "$(CURDIR)/topbar-icon.png" "$(RES_DIR)/StatusItem.png"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@echo "bundled -> $(APP_DIR)"

sign: bundle
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements "$(CURDIR)/Resources/Blip.entitlements" \
		--identifier "$(BUNDLE_ID)" \
		--timestamp=none \
		"$(APP_DIR)" 2>&1 | sed 's/^/  /'
	@codesign --verify --verbose=2 "$(APP_DIR)" 2>&1 | sed 's/^/  /'
	@echo "signed as $(BUNDLE_ID)"

# Relaunch. Killing first avoids two event taps fighting over the same hotkey.
run: stop sign
	@open "$(APP_DIR)"
	@echo "launched $(APP_NAME)"

stop:
	@pkill -x "$(APP_NAME)" 2>/dev/null || true

test:
	swift test

probe:
	swift build -c $(CONFIG) --product blip-probe

# Prints the designated requirement TCC actually matches against. If this changes
# between builds, permissions will reset -- that is the thing to check first.
identity: sign
	@codesign -d -r- "$(APP_DIR)" 2>&1 | sed 's/^/  /'

clean:
	rm -rf .build "$(BUILD_DIR)"
