APP        = BlackPearl
BUNDLE_ID  = com.highlifestyle.blackpearl
VERSION   ?= 0.1.0
BUILD_DIR  = .build/release
APP_DIR    = dist/$(APP).app

.PHONY: build test app run install zip clean

build:
	swift build -c release

test:
	swift test

app: build
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"
	cp "$(BUILD_DIR)/$(APP)" "$(APP_DIR)/Contents/MacOS/$(APP)"
	sed 's/__VERSION__/$(VERSION)/g' Support/Info.plist > "$(APP_DIR)/Contents/Info.plist"
	if [ -f Support/AppIcon.icns ]; then cp Support/AppIcon.icns "$(APP_DIR)/Contents/Resources/"; fi
	codesign --force --sign - --identifier $(BUNDLE_ID) "$(APP_DIR)"
	@echo "Built $(APP_DIR)"

run: app
	open "$(APP_DIR)"

install: app
	rm -rf "/Applications/$(APP).app"
	cp -R "$(APP_DIR)" /Applications/
	@echo "Installed /Applications/$(APP).app"

zip: app
	cd dist && ditto -c -k --keepParent "$(APP).app" "$(APP)-$(VERSION).zip"
	@echo "Wrote dist/$(APP)-$(VERSION).zip"

clean:
	rm -rf .build dist
