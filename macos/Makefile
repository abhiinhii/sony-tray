# Sony Tray for macOS — swiftc-driven build.
#
# Package.swift describes the same targets for SwiftPM/Xcode users, but SwiftPM is not the
# supported path here: a Command-Line-Tools-only Mac can have a libPackageDescription.dylib that
# no longer matches its own .swiftmodule, so `swift build` fails to link its manifest. This
# Makefile drives swiftc directly and needs nothing but the CLT.

SWIFTC   := swiftc
BUILD    := build
DEPLOY   := 13.0
ARCH     := $(shell uname -m)
CONFIG   ?= release
APP      := $(BUILD)/SonyTray.app
KIT_SRC  := $(wildcard Sources/SonyProtocolKit/*.swift)
APP_SRC  := $(wildcard Sources/SonyTrayMac/*.swift)
TEST_SRC := $(wildcard Sources/SonyProtocolTests/*.swift)

# Empty on a healthy toolchain; see scripts/swift-compat-flags.sh.
COMPAT := $(shell sh scripts/swift-compat-flags.sh $(BUILD))

ifeq ($(CONFIG),release)
SWIFTFLAGS := -O
else
SWIFTFLAGS := -Onone -g
endif

SWIFTFLAGS += $(COMPAT)

# Universal by default so the built .app runs on Apple Silicon and Intel. `make app UNIVERSAL=0`
# builds only for this machine (faster).
UNIVERSAL ?= 1
ifeq ($(UNIVERSAL),1)
TARGETS := arm64-apple-macos$(DEPLOY) x86_64-apple-macos$(DEPLOY)
else
TARGETS := $(ARCH)-apple-macos$(DEPLOY)
endif

.PHONY: all test app run probe snapshot install uninstall clean

all: app

# --- protocol core + tests ---------------------------------------------------------------

$(BUILD)/lib/libSonyProtocolKit.a: $(KIT_SRC)
	@mkdir -p $(BUILD)/lib
	@$(SWIFTC) $(SWIFTFLAGS) -target $(ARCH)-apple-macos$(DEPLOY) \
		-module-name SonyProtocolKit \
		-emit-module -emit-module-path $(BUILD)/lib/SonyProtocolKit.swiftmodule \
		-emit-library -static -o $@ \
		$(KIT_SRC)

$(BUILD)/SonyProtocolTests: $(BUILD)/lib/libSonyProtocolKit.a $(TEST_SRC)
	@mkdir -p $(BUILD)
	@$(SWIFTC) $(SWIFTFLAGS) -target $(ARCH)-apple-macos$(DEPLOY) \
		-I $(BUILD)/lib -L $(BUILD)/lib -lSonyProtocolKit \
		-o $@ $(TEST_SRC)

test: $(BUILD)/SonyProtocolTests
	@$<

# --- app bundle --------------------------------------------------------------------------

app: $(APP)

# Per slice: build SonyProtocolKit as its own module, then the app against it. Keeping the module
# boundary means the sources compile identically here and under SwiftPM/Xcode.
$(APP): $(KIT_SRC) $(APP_SRC) Resources/Info.plist
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@for t in $(TARGETS); do \
		echo "  compiling $$t"; \
		d=$(BUILD)/slices/$$t; mkdir -p $$d; \
		$(SWIFTC) $(SWIFTFLAGS) -target $$t \
			-module-name SonyProtocolKit \
			-emit-module -emit-module-path $$d/SonyProtocolKit.swiftmodule \
			-emit-library -static -o $$d/libSonyProtocolKit.a \
			$(KIT_SRC) || exit 1; \
		$(SWIFTC) $(SWIFTFLAGS) -target $$t \
			-module-name SonyTrayMac \
			-I $$d -L $$d -lSonyProtocolKit \
			-framework IOBluetooth -framework AppKit -framework ServiceManagement \
			-o $$d/SonyTray $(APP_SRC) || exit 1; \
	done
	@lipo -create $(foreach t,$(TARGETS),$(BUILD)/slices/$(t)/SonyTray) \
		-output $(APP)/Contents/MacOS/SonyTray
	@cp Resources/Info.plist $(APP)/Contents/Info.plist
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(APP)/Contents/Resources/; fi
	@printf 'APPL????' > $(APP)/Contents/PkgInfo
	@codesign --force --sign - --identifier com.sonytray.mac $(APP) 2>/dev/null \
		&& echo "  signed (ad-hoc)" \
		|| echo "  warning: ad-hoc signing failed; Bluetooth access may be denied"
	@echo "built $(APP)"

run: app
	@pkill -x SonyTray 2>/dev/null || true
	@open $(APP)

# Console connectivity harness — connects, prints the handshake, exercises a round-trip, exits.
probe: app
	@$(APP)/Contents/MacOS/SonyTray --probe

# Flyout layout smoke test — renders the popover offscreen to a PNG. No Bluetooth involved.
snapshot: app
	@$(APP)/Contents/MacOS/SonyTray --snapshot $(BUILD)/flyout.png

# Install into /Applications. Worth doing rather than running from build/: SMAppService registers
# the bundle at its current path as the login item, so "Launch at Login" only survives if the app
# lives somewhere stable. Override with `make install PREFIX=~/Applications`.
PREFIX ?= /Applications

install: app
	@pkill -x SonyTray 2>/dev/null || true
	@rm -rf "$(PREFIX)/SonyTray.app"
	@mkdir -p "$(PREFIX)"
	@cp -R $(APP) "$(PREFIX)/"
	@echo "installed $(PREFIX)/SonyTray.app  —  open it with: open '$(PREFIX)/SonyTray.app'"

uninstall:
	@pkill -x SonyTray 2>/dev/null || true
	@rm -rf "$(PREFIX)/SonyTray.app"
	@echo "removed $(PREFIX)/SonyTray.app (logs remain in ~/Library/Logs/SonyTray)"

clean:
	@rm -rf $(BUILD)
	@echo "cleaned"
