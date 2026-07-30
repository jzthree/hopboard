# flowboard — build, test, and install without remembering flags.
#   make test       run the unit suite in the simulator
#   make install    build signed (Release) and install to the iPhone
#   make sim        build + launch in the simulator
#   make shot       screenshot the simulator to /tmp/flowboard.png
DEVICE ?= FA720813-48B6-5E57-984D-C76733368A9D
SIMNAME ?= iPhone 17 Pro
SIM ?= 56F2687C-0938-490F-ABC4-18461A4D8F36
BUNDLE = io.zhoulab.flowboard
PROJECT = FlowBoard.xcodeproj
SCHEME = FlowBoard
APP = build/Build/Products/Release-iphoneos/FlowBoard.app
SIMAPP = build-sim/Build/Products/Debug-iphonesimulator/FlowBoard.app
# Every install identifiable on the device (learned from hop-ios).
BUILDNO = $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
VERSION_FLAGS = CURRENT_PROJECT_VERSION=$(BUILDNO)

.PHONY: gen build test sim simbuild install shot clean

gen:
	xcodegen

# Release for the phone: Whisper feature extraction and SwiftUI diffing
# should not run -Onone on the build that lives on the device.
build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
	  -destination 'generic/platform=iOS' -allowProvisioningUpdates \
	  -derivedDataPath build $(VERSION_FLAGS) build

test: gen
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
	  -destination 'platform=iOS Simulator,name=$(SIMNAME)' \
	  -derivedDataPath build-sim CODE_SIGNING_ALLOWED=NO

simbuild: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination 'platform=iOS Simulator,name=$(SIMNAME)' \
	  -derivedDataPath build-sim CODE_SIGNING_ALLOWED=NO $(VERSION_FLAGS) build

sim: simbuild
	-xcrun simctl boot $(SIM) 2>/dev/null
	-xcrun simctl terminate $(SIM) $(BUNDLE) 2>/dev/null
	xcrun simctl install $(SIM) $(SIMAPP)
	xcrun simctl launch $(SIM) $(BUNDLE)

# Wi-Fi installs are flaky (DeviceLocked / immediate disconnect): retry,
# and use a cable for a one-shot install.
install: build
	@for i in $$(seq 1 15); do \
	  out=$$(xcrun devicectl device install app --device $(DEVICE) "$(APP)" 2>&1); \
	  if echo "$$out" | grep -qE "App installed|installationURL|Complete!"; then echo "installed (attempt $$i)"; exit 0; fi; \
	  echo "attempt $$i: $$(echo "$$out" | grep -oE 'DeviceLocked|disconnected immediately|not paired|unavailable' | head -1)"; sleep 8; \
	done; echo "install failed — unlock the phone or plug in a cable"; exit 1

shot:
	xcrun simctl io $(SIM) screenshot /tmp/flowboard.png && echo "wrote /tmp/flowboard.png"

clean:
	rm -rf build build-sim $(PROJECT)

# TestFlight: archive (dev-signed) then export re-signs with the ASC-minted
# "FlowBoard AppStore" profiles and uploads. Needs the app record to exist
# in App Store Connect (browser, once). Profiles: scripts/mint_dist_profiles.py.
ASC_KEY = $(HOME)/.appstoreconnect/private_keys/AuthKey_CCFL4WD4V4.p8
ASC_AUTH = -authenticationKeyPath $(ASC_KEY) -authenticationKeyID CCFL4WD4V4 \
           -authenticationKeyIssuerID 254072af-7f14-4065-acd8-d09fe4924553

archive: gen
	xcodebuild archive -project $(PROJECT) -scheme $(SCHEME) \
	  -destination 'generic/platform=iOS' \
	  -archivePath build/FlowBoard.xcarchive $(VERSION_FLAGS)

testflight: archive
	xcodebuild -exportArchive -archivePath build/FlowBoard.xcarchive \
	  -exportOptionsPlist AppStore/ExportOptions.plist -exportPath build/export \
	  $(ASC_AUTH)
	uv run scripts/testflight.py release
