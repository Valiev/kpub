SHELL := /bin/bash
CONFIGURATION ?= release
INSTALL_DIR ?= $(HOME)/Applications
SKILLS_DIR ?= $(HOME)/.codex/skills
APP := build/kpub.app

.PHONY: all help build test app install run clean skill-install check dist
all: app
help:
	@echo 'Targets: build test app install run clean check dist skill-install version bump'
	@echo 'Options: CONFIGURATION=debug INSTALL_DIR=/Applications SKILLS_DIR=...'
build:
	swift build -c $(CONFIGURATION) --product kpub
test:
	swift test
app:
	CONFIGURATION=$(CONFIGURATION) bash scripts/build-app.sh
install: app
	mkdir -p "$(INSTALL_DIR)"
	ditto "$(APP)" "$(INSTALL_DIR)/kpub.app"
run: app
	open "$(APP)"
clean:
	swift package clean
check: test app
	plutil -lint Resources/Info.plist
	codesign --verify --deep --strict "$(APP)"
dist: check
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" build/kpub-$(shell python3 scripts/version.py)-macos.zip
skill-install:
	mkdir -p "$(SKILLS_DIR)/kpub"
	cp skills/kpub/SKILL.md "$(SKILLS_DIR)/kpub/SKILL.md"

.PHONY: version bump
version:
	@python3 scripts/version.py
bump:
	python3 scripts/version.py $(PART)
