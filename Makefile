SRC_DIR := src

LUALS_VERSION := 3.17.1
LUALS_DIR := bin/lua-language-server
LUALS := $(LUALS_DIR)/bin/lua-language-server
LUALS_URL := https://github.com/LuaLS/lua-language-server/releases/download/$(LUALS_VERSION)/lua-language-server-$(LUALS_VERSION)-linux-x64.tar.gz

.PHONY: help install-tools install-stylua install-luals format format-check typecheck check sync push

help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "  install-tools   Install stylua and lua-language-server"
	@echo "  install-stylua  Install stylua (via cargo)"
	@echo "  install-luals   Install lua-language-server"
	@echo "  format          Format Lua files with stylua"
	@echo "  format-check    Check formatting without modifying files"
	@echo "  typecheck       Run lua-language-server type checking"
	@echo "  check           Run format-check and typecheck"
	@echo "  sync            Sync source files to EdgeTX simulator SD card"
	@echo "  push            Install package to EdgeTX radio and eject"

install-stylua:
	@command -v cargo >/dev/null 2>&1 || { echo "cargo is required (install Rust: https://rustup.rs)"; exit 1; }
	cargo install stylua --features lua53

install-luals:
	mkdir -p $(LUALS_DIR)
	curl -fSL $(LUALS_URL) | tar xz -C $(LUALS_DIR)

install-tools: install-stylua install-luals

format:
	stylua $(SRC_DIR)

format-check:
	stylua --check $(SRC_DIR)

typecheck:
	$(LUALS) --check .

check: format-check typecheck

sync:
	edgetx-cli dev sync ../edgetx-sdcard

push:
	edgetx-cli pkg install . --eject
