.PHONY: pwa mac-app mac-app-signed run run-signed

pwa:
	./scripts/build-pwa.sh

mac-app: pwa
	./scripts/build-mac-app.sh

mac-app-signed: mac-app
	bash apps/mac-app/scripts/resign-mac-app.sh

run: mac-app
	open ./apps/mac-app/.build/Insta360Sync.app

run-signed: mac-app-signed
	open ./apps/mac-app/.build/Insta360Sync.app
