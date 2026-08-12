# vc-terminal (Alacritty fork) — canonical build / release surface
# 𝚅𝚒𝚋𝚎𝚌𝚛𝚊𝚏𝚝𝚎𝚍. with AI Agents by Vetcoders (c)2024-2026 LibraxisAI
#
# Shape mirrors labs/vc-surface (wezterm fork): help/precheck/gates +
# codescribe-shaped app/dmg-signed/notarize release surface.

.PHONY: all help build release-bins binary binary-universal check clippy fmt fmt-check precheck \
	test icons doctor info-certs clean distclean \
	app app-local dmg dmg-signed notarize \
	release release-local release-install install \
	run

# ──────────────────────────────────────────────────────────
# Config
# ──────────────────────────────────────────────────────────

CARGO ?= cargo
BUILD_OPTS ?=
APP_NAME := vc-terminal
DIST_DIR := $(CURDIR)/dist
APP_BUNDLE := $(DIST_DIR)/$(APP_NAME).app
DMG_DIR ?= $(HOME)/Libraxis/vc-runtime/releases/dmg
DMG_PATH ?= $(DMG_DIR)/$(APP_NAME).dmg
RELEASE_SH := bash scripts/build-vc-terminal-release.sh
DEPLOYMENT_TARGET := MACOSX_DEPLOYMENT_TARGET="10.12"

export CARGO_TERM_COLOR ?= always

C_CYAN   := \033[36m
C_GREEN  := \033[32m
C_YELLOW := \033[33m
C_RESET  := \033[0m

# ──────────────────────────────────────────────────────────
# Default
# ──────────────────────────────────────────────────────────

## Default: show help (build system is the product surface)
all: help

## Show this help
help:
	@printf "\n$(C_CYAN)vc-terminal$(C_RESET) — Alacritty fork · product ship surface\n"
	@printf "$(C_CYAN)────────────────────────────────────────────────────────────────────────$(C_RESET)\n\n"
	@printf "  $(C_YELLOW)BUILD$(C_RESET)\n"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "build" "Debug cargo build"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "release-bins" "Release cargo binary only (no .app)"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "binary" "Alias of release-bins"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "binary-universal" "Universal (x86_64+aarch64) release binary"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "icons" "Rebuild terminal.png / alacritty.icns (full-bleed)"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "run" "Launch dist/vc-terminal.app if present"
	@printf "\n  $(C_YELLOW)QUALITY GATES$(C_RESET)\n"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "precheck" "fmt-check + check + release script syntax"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "check" "cargo check (workspace)"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "clippy" "cargo clippy -D warnings"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "fmt" "cargo +nightly fmt"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "fmt-check" "fmt --check"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "test" "cargo test (workspace)"
	@printf "\n  $(C_YELLOW)APP / DMG / NOTARIZE$(C_RESET)  $(C_CYAN)(codescribe-shaped)$(C_RESET)\n"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "app" "Build + layout + sign .app (no DMG, no notary)"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "app-local" "Alias of app"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "dmg" "Alias of dmg-signed (Developer ID signed DMG)"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "dmg-signed" "Build + sign .app + signed DMG (no notary)"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "notarize" "Notarize+staple existing .app + DMG"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "release" "Full: sign + notarize app + DMG"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "release-local" "Same as dmg-signed (compat)"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "release-install" "dmg-signed + install to /Applications"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "install" "Alias of release-install"
	@printf "\n  $(C_YELLOW)INSPECTION$(C_RESET)\n"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "doctor" "Env + paths + certs + dist state"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "info-certs" "List codesigning identities"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "clean" "Remove dist/"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "distclean" "dist/ + cargo clean"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "help" "Show this help"
	@printf "\n  $(C_CYAN)Quick start:$(C_RESET)\n"
	@printf "    make precheck\n"
	@printf "    make icons && make dmg-signed\n"
	@printf "    make notarize                  # after dmg-signed\n"
	@printf "    make release                   # sign+notarize end-to-end\n"
	@printf "    make release-install           # local signed DMG + /Applications\n\n"
	@printf "  $(C_CYAN)Outputs:$(C_RESET)\n"
	@printf "    App: $(APP_BUNDLE)\n"
	@printf "    DMG: $(DMG_PATH)\n\n"
	@printf "  $(C_CYAN)Credentials:$(C_RESET) \$$KEYS (default ~/.keys)\n"
	@printf "    signing-identity.txt · Certificates.p12 · .notary.env or NOTARY_PROFILE\n\n"

# ──────────────────────────────────────────────────────────
# Build
# ──────────────────────────────────────────────────────────

## Debug build
build:
	$(DEPLOYMENT_TARGET) $(CARGO) build $(BUILD_OPTS)

## Release binary only (no .app layout)
release-bins binary:
	$(DEPLOYMENT_TARGET) $(CARGO) build --release

## Universal release binary (both architectures, lipo-merged)
binary-universal:
	$(DEPLOYMENT_TARGET) $(CARGO) build --release --target=x86_64-apple-darwin
	$(DEPLOYMENT_TARGET) $(CARGO) build --release --target=aarch64-apple-darwin
	@lipo target/{x86_64,aarch64}-apple-darwin/release/alacritty -create -output target/release/alacritty

## Rebuild icons (full-bleed icns from assets/icon/vc-terminal-icon.png)
icons:
	assets/icon/update.sh

## Launch staged app if present
run:
	@test -d "$(APP_BUNDLE)" || { echo "missing $(APP_BUNDLE) — run make app first"; exit 1; }
	open "$(APP_BUNDLE)"

# ──────────────────────────────────────────────────────────
# Quality gates
# ──────────────────────────────────────────────────────────

## Typecheck workspace
check:
	$(CARGO) check --workspace

## Clippy on the whole workspace
clippy:
	$(CARGO) clippy --workspace --all-targets -- -D warnings

## Format (nightly rustfmt — rustfmt.toml uses unstable options)
fmt:
	$(CARGO) +nightly fmt

## Format check
fmt-check:
	$(CARGO) +nightly fmt -- --check

## Pre-push style gate (integrators start here)
precheck:
	@echo "╔══════════════════════════════════════╗"
	@echo "║  vc-terminal precheck                ║"
	@echo "╚══════════════════════════════════════╝"
	@echo ""
	@echo "→ [1/3] Formatting..."
	@$(CARGO) +nightly fmt -- --check || { echo "✗ Run 'make fmt'"; exit 1; }
	@echo "✓ Format OK"
	@echo ""
	@echo "→ [2/3] Typecheck..."
	@$(MAKE) --no-print-directory check
	@echo "✓ Check OK"
	@echo ""
	@echo "→ [3/3] Release script syntax..."
	@bash -n scripts/build-vc-terminal-release.sh
	@echo "✓ release.sh OK"
	@echo ""
	@echo "══════════════════════════════════════"
	@echo "  ✓ precheck passed"

## Tests
test:
	$(CARGO) test --workspace

# ──────────────────────────────────────────────────────────
# App / DMG / Notarize  (codescribe-shaped)
# ──────────────────────────────────────────────────────────

## Build + layout + sign .app only (no DMG, no notary)
app app-local: icons
	$(RELEASE_SH) --no-notarize --skip-dmg

## Developer ID signed DMG (no notary) — primary integrator artifact
dmg dmg-signed: icons
	$(RELEASE_SH) --no-notarize

## Notarize+staple existing .app and DMG (after dmg-signed)
notarize:
	@test -d "$(APP_BUNDLE)" || { echo "missing $(APP_BUNDLE) — run make dmg-signed first"; exit 1; }
	@test -f "$(DMG_PATH)" || { echo "missing $(DMG_PATH) — run make dmg-signed first"; exit 1; }
	$(RELEASE_SH) --notarize-only

## Full public path: sign + notarize app + DMG
release: icons
	$(RELEASE_SH)

## Compat: local signed ship without notary
release-local: dmg-signed

## Signed local DMG + install to /Applications
release-install install: icons
	$(RELEASE_SH) --no-notarize --install

# ──────────────────────────────────────────────────────────
# Inspection / housekeeping
# ──────────────────────────────────────────────────────────

## Env + certs + dist snapshot
doctor:
	@echo "vc-terminal doctor"
	@echo "  repo:     $(CURDIR)"
	@echo "  cargo:    $$($(CARGO) --version 2>/dev/null || echo missing)"
	@echo "  rustc:    $$(rustc --version 2>/dev/null || echo missing)"
	@echo "  app:      $(APP_BUNDLE) $$(test -d '$(APP_BUNDLE)' && echo '[present]' || echo '[missing]')"
	@echo "  dmg:      $(DMG_PATH) $$(test -f '$(DMG_PATH)' && echo '[present]' || echo '[missing]')"
	@echo "  icons:    $$(test -f extra/osx/$(APP_NAME).app/Contents/Resources/alacritty.icns && echo ok || echo MISSING)"
	@echo "  keys:     $${KEYS:-$$HOME/.keys}"
	@echo "  identity: $$(test -f $${KEYS:-$$HOME/.keys}/signing-identity.txt && head -1 $${KEYS:-$$HOME/.keys}/signing-identity.txt || echo missing)"
	@echo "  notary:   $${NOTARY_PROFILE:-unset} / $$(test -f $${KEYS:-$$HOME/.keys}/.notary.env && echo .notary.env || echo no-.notary.env)"
	@$(MAKE) --no-print-directory info-certs

## List codesigning identities
info-certs:
	@security find-identity -v -p codesigning 2>/dev/null | grep -E "Developer ID|Apple Development" || true

## Remove dist/
clean:
	rm -rf "$(DIST_DIR)"

## dist/ + cargo clean
distclean: clean
	$(CARGO) clean
