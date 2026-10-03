# AgentDeck — build, run, test, install.
PROJECT      := AgentDeck.xcodeproj
SCHEME       := AgentDeck
DERIVED      := build
DEBUG_APP    := $(DERIVED)/Build/Products/Debug/AgentDeck.app
RELEASE_APP  := $(DERIVED)/Build/Products/Release/AgentDeck.app
XCODEBUILD   := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64' -quiet

.PHONY: all build release run mock test install uninstall clean kill

all: build

build:
	$(XCODEBUILD) -configuration Debug build

release:
	$(XCODEBUILD) -configuration Release build

kill:
	@pkill -x AgentDeck 2>/dev/null; sleep 0.3; true

run: build kill
	open $(DEBUG_APP)

mock: build kill
	open -n $(DEBUG_APP) --args -mock

test:
	cd AgentDeckCore && swift test

install: release kill
	rm -rf /Applications/AgentDeck.app
	ditto $(RELEASE_APP) /Applications/AgentDeck.app
	@echo "Installed /Applications/AgentDeck.app"
	open /Applications/AgentDeck.app

uninstall: kill
	rm -rf /Applications/AgentDeck.app

clean:
	rm -rf $(DERIVED)
	cd AgentDeckCore && swift package clean
