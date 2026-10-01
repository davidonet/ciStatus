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
	@echo "Tokens are read from the environment, so launching from Finder or"
	@echo "Spotlight will not see them. Launch it from a terminal instead:"
	@echo
	@echo "  GITHUB_API_KEY=… VERCEL_API_KEY=… SENTRY_API_KEY=… open -a $(APP_NAME)"
	@echo
	@echo "Or use 'make install-and-run' once to set it up for login."

.PHONY: uninstall
uninstall:
	@-pkill -x $(APP_NAME) 2>/dev/null || true
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Removed $(INSTALL_DIR)/$(APP_NAME).app"

# Launching with the environment inherited is the only reliable way to pass
# tokens, since neither Finder nor `open` forward one.
.PHONY: run
run: build
	@echo "Launching $(APP) with the current environment"
	"$(APP)/Contents/MacOS/$(APP_NAME)"

# Installs a LaunchAgent so it starts at login with the tokens loaded from a
# gitignored file, which removes the manual launch step.
.PHONY: install-and-run
install-and-run: install
	@echo "For a login item with tokens, run:"
	@echo "  ./Scripts/install-launch-agent.sh"

.PHONY: probe
probe:
	@swift build --product probe
	@./.build/debug/probe "$(HOME)/Library/Application Support/$(APP_NAME)/config.json"

.PHONY: clean
clean:
	rm -rf .build build
