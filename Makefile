.PHONY: install api web test dev stop-api mac-gen mac mac-icons mac-build mac-release mac-install win-install win-dev win-build win-ci

ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
MAC_DIR := $(ROOT)mac
WIN_DIR := $(ROOT)win
DEVELOPMENT_TEAM ?=
MAC_CONFIG ?= Debug

install:
	cd $(ROOT) && uv sync --all-packages --python 3.12

stop-api:
	@lsof -ti :8001 | xargs kill -9 2>/dev/null || true

api: stop-api
	cd $(ROOT) && uv run uvicorn markitdown_api.main:app --host 0.0.0.0 --port 8001 --reload --app-dir api

web:
	cd $(ROOT)web && npm run dev

dev:
	@echo "Run in two terminals: make api && make web"
	@echo "Web: http://localhost:5174  API: http://localhost:8001"

test:
	cd $(ROOT) && uv run pytest tests/ -q

mac-gen:
	cd $(MAC_DIR) && xcodegen generate

mac: mac-gen
	@open $(MAC_DIR)/OCRReview.xcodeproj 2>/dev/null || echo "Open mac/OCRReview.xcodeproj in Xcode"

mac-icons:
	$(MAC_DIR)/scripts/generate_icons.sh $(MAC_DIR)/design/app-icon-1024.png

mac-build: mac-gen
	cd $(MAC_DIR) && xcodebuild \
	  -project OCRReview.xcodeproj \
	  -scheme OCRReview \
	  -configuration $(MAC_CONFIG) \
	  -derivedDataPath build \
	  -destination 'platform=macOS' \
	  DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" \
	  build
	@echo "Built: $(MAC_DIR)/build/Build/Products/$(MAC_CONFIG)/OCR Review.app"

mac-release: MAC_CONFIG=Release
mac-release: mac-build

mac-install: mac-release
	cp -R "$(MAC_DIR)/build/Build/Products/Release/OCR Review.app" /Applications/
	@echo "Installed OCR Review.app to /Applications"

win-install:
	cd $(WIN_DIR) && npm install

win-dev: win-install
	cd $(WIN_DIR) && npm run tauri:dev

win-build: win-install
	cd $(WIN_DIR) && npm run tauri:build
	@echo "Built Windows app in $(WIN_DIR)/src-tauri/target/release/"

win-ci:
	@echo "Build a Windows installer in the cloud (no tools on your PC):"
	@echo "  1. Push this repo to GitHub"
	@echo "  2. Actions → Build Windows → Run workflow"
	@echo "  3. Download artifact: OCR-Review-Windows"
	@echo "  4. Copy OCR Review_*_setup.exe to your Windows laptop and install"
	@echo ""
	@echo "End users need ZERO dev tools — see win/GET-STARTED.md"
