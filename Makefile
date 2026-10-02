# Build, test, and install ciStatus.
#
# `make release` produces build/CIStatus.app, which is the thing to ship or
# install. The SwiftPM binary on its own is not usable as a menu bar app.

APP_NAME    := CIStatus
APP         := build/$(APP_NAME).app
CONFIG      ?= release
INSTALL_DIR ?= /Applications

.PHONY: help
help:
	@echo "make            build and install to $(INSTALL_DIR)"
	@echo "make build      build $(APP) only"
	@echo "make run        build and launch, passing the current environment"
	@echo "make test       run the unit tests"
	@echo "make probe      print what the app would show for your config"
	@echo "make install    install to $(INSTALL_DIR)"
	@echo "make uninstall  remove it from $(INSTALL_DIR)"
	@echo "make clean      remove build products"

.PHONY: all
all: install

.PHONY: build
build:
	swift build -c $(CONFIG)
	./Scripts/build-app.sh $(APP)

.PHONY: test
test:
	swift test

.PHONY: install
install: build
	@# An already running copy holds the old binary open, so replace it first.
	@-pkill -x $(APP_NAME) 2>/dev/null || true
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R $(APP) "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"
	@echo
	@echo "Tokens live in ~/Library/Application Support/CIStatus/tokens.json,"
	@echo "so the app launches from Finder or Spotlight. Add one from the"
	@echo "Settings window, or:"
	@echo
	@echo "  swift build --product probe && .build/debug/probe --store-token github <token>"
	@echo
	@echo "Or use 'make install-and-run' once to set it up for login."

.PHONY: uninstall
uninstall:
	@-pkill -x $(APP_NAME) 2>/dev/null || true
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Removed $(INSTALL_DIR)/$(APP_NAME).app"

.PHONY: run
run: build
	@echo "Launching $(APP)"
	"$(APP)/Contents/MacOS/$(APP_NAME)"

# Installs a LaunchAgent so it starts at login, which removes the manual launch
# step.
.PHONY: install-and-run
install-and-run: install
	@echo "For a login item, run:"
	@echo "  ./Scripts/install-launch-agent.sh --install-tokens"

.PHONY: probe
probe:
	@swift build --product probe
	@./.build/debug/probe --diagnose "$(HOME)/Library/Application Support/$(APP_NAME)/config.json"

# Says what is stored, what is enabled and what is missing, without polling.
.PHONY: doctor
doctor:
	@swift build --product probe
	@./.build/debug/probe --tokens
	@echo
	@echo "Log: ~/Library/Logs/CIStatus/ciStatus.log"

.PHONY: clean
clean:
	rm -rf .build build
