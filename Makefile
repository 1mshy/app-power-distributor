APP := build/App Power Distributor.app

.PHONY: build test app install clean

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

install: app
	rm -rf "/Applications/App Power Distributor.app"
	cp -R "$(APP)" /Applications/
	@echo "Installed /Applications/App Power Distributor.app"
	@echo "To use the command line tool:"
	@echo "  sudo ln -sf '/Applications/App Power Distributor.app/Contents/MacOS/apd' /usr/local/bin/apd"

clean:
	rm -rf .build build
