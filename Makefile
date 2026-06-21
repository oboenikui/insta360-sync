.PHONY: pwa mac-app run

pwa:
	./scripts/build-pwa.sh

mac-app: pwa
	./scripts/build-mac-app.sh

run: mac-app
	open ./apps/mac-app/.build/Insta360Sync.app
