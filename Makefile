# vc-terminal (Alacritty fork) — deterministic terminal substrate
# 𝚅𝚒𝚋𝚎𝚌𝚛𝚊𝚏𝚝𝚎𝚍. with AI Agents by Vetcoders (c)2024-2026 LibraxisAI
#
# Vibecrafted owns app/DMG/install/update. This repository only supplies
# deterministic binaries and quality gates to the parent release builder.

.PHONY: all help build release-bins binary binary-universal check clippy fmt fmt-check precheck \
	test icons doctor clean distclean run

# ──────────────────────────────────────────────────────────
# Config
# ──────────────────────────────────────────────────────────

CARGO ?= cargo
BUILD_OPTS ?=
APP_NAME := vc-terminal
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
	@printf "\n$(C_CYAN)vc-terminal$(C_RESET) — Alacritty fork · Vibecrafted donor surface\n"
	@printf "$(C_CYAN)────────────────────────────────────────────────────────────────────────$(C_RESET)\n\n"
	@printf "  $(C_YELLOW)BUILD$(C_RESET)\n"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "build" "Debug cargo build"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "release-bins" "Release cargo binary only (no .app)"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "binary" "Alias of release-bins"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "binary-universal" "Universal (x86_64+aarch64) release binary"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "icons" "Rebuild terminal.png / alacritty.icns (full-bleed)"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "run" "Run the terminal from source"
	@printf "\n  $(C_YELLOW)QUALITY GATES$(C_RESET)\n"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "precheck" "fmt-check + check + donor release build"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "check" "cargo check (workspace)"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "clippy" "cargo clippy -D warnings"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "fmt" "cargo +nightly fmt"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "fmt-check" "fmt --check"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "test" "cargo test (workspace)"
	@printf "\n  $(C_YELLOW)INSPECTION$(C_RESET)\n"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "doctor" "Toolchain + donor binary state"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "clean" "Remove dist/"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "distclean" "dist/ + cargo clean"
	@printf "    $(C_GREEN)%-16s$(C_RESET) %s\n" "help" "Show this help"
	@printf "\n  $(C_CYAN)Integrator contract:$(C_RESET)\n"
	@printf "    make precheck\n"
	@printf "    make release-bins              # consumed by Vibecrafted.app builder\n\n"
	@printf "  Packaging, signing, notarization, installation and updates are owned by\n"
	@printf "  the sibling vibecrafted repository and its single Vibecrafted.dmg.\n\n"

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

## Run from source
run:
	$(CARGO) run --bin alacritty

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
	@echo "→ [3/3] Donor release binary..."
	@$(MAKE) --no-print-directory release-bins
	@echo "✓ donor binary OK"
	@echo ""
	@echo "══════════════════════════════════════"
	@echo "  ✓ precheck passed"

## Tests
test:
	$(CARGO) test --workspace

# ──────────────────────────────────────────────────────────
# Inspection / housekeeping
# ──────────────────────────────────────────────────────────

## Env + certs + dist snapshot
doctor:
	@echo "vc-terminal doctor"
	@echo "  repo:     $(CURDIR)"
	@echo "  cargo:    $$($(CARGO) --version 2>/dev/null || echo missing)"
	@echo "  rustc:    $$(rustc --version 2>/dev/null || echo missing)"
	@echo "  binary:   $(CURDIR)/target/release/alacritty $$(test -x '$(CURDIR)/target/release/alacritty' && echo '[present]' || echo '[missing]')"
	@echo "  icons:    $$(test -f extra/osx/$(APP_NAME).app/Contents/Resources/alacritty.icns && echo ok || echo MISSING)"

## Remove dist/
clean:
	$(CARGO) clean -p alacritty

## dist/ + cargo clean
distclean: clean
	$(CARGO) clean
