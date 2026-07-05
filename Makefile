.PHONY: pwa mac-app mac-app-signed run run-signed

APP_BUNDLE := $(CURDIR)/apps/mac-app/.build/Insta360Sync.app

pwa:
	./scripts/build-pwa.sh

mac-app: pwa
	./scripts/build-mac-app.sh

mac-app-signed: mac-app
	bash apps/mac-app/scripts/resign-mac-app.sh

run: mac-app
	-pkill -x Insta360Sync
	@sleep 0.3
	open "$(APP_BUNDLE)"

run-signed: mac-app-signed
	-pkill -x Insta360Sync
	@sleep 0.3
	open "$(APP_BUNDLE)"
