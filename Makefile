.PHONY: pwa mac-app mac-app-signed install run run-signed

APP_BUNDLE := $(CURDIR)/apps/mac-app/.build/Insta360Sync.app
INSTALL_DIR ?= /Applications

pwa:
	./scripts/build-pwa.sh

mac-app: pwa
	./scripts/build-mac-app.sh

mac-app-signed: mac-app
	bash apps/mac-app/scripts/resign-mac-app.sh

install: mac-app-signed
	INSTALL_DIR="$(INSTALL_DIR)" APP_BUNDLE="$(APP_BUNDLE)" ./scripts/install-mac-app.sh

run: mac-app
	-pkill -x Insta360Sync
	@sleep 0.3
	open "$(APP_BUNDLE)"

run-signed: mac-app-signed
	-pkill -x Insta360Sync
	@sleep 0.3
	open "$(APP_BUNDLE)"
