#!/usr/bin/env bash
# vc-terminal release pipeline (stages compose via flags):
#   cargo release build → vc-terminal.app → sign → [notarize app]
#     → DMG → sign DMG → [notarize DMG] → [install]
#
# Flow ported from labs/vc-surface (wezterm fork) onto the Alacritty fork —
# same stages, same credential surface, alacritty-shaped layout.
#
# Flags (make targets map onto these):
#   --no-notarize     skip Apple notary (default for dmg-signed / release-local)
#   --skip-build      reuse target/release binaries
#   --skip-dmg        stop after signed (.app) [make app]
#   --notarize-only   notarize+staple existing app + DMG (make notarize)
#   --install         copy app to /Applications
#   --clean           wipe dist/ before layout
#
# Credentials:
#   signing identity: $KEYS/signing-identity.txt, default $HOME/.keys
#   notary: NOTARY_PROFILE keychain profile, or $KEYS/.notary.env fallback
#
# Make surface:
#   make app | dmg-signed | notarize | release | release-local | release-install

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist}"
APP_NAME="vc-terminal"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_TEMPLATE="$REPO_ROOT/extra/osx/$APP_NAME.app"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
DMG_DIR="${DMG_DIR:-$HOME/Libraxis/vc-runtime/releases/dmg}"
DMG_PATH="${DMG_PATH:-$DMG_DIR/$APP_NAME.dmg}"
KEYS="${KEYS:-$HOME/.keys}"
NOTARY_ENV="$KEYS/.notary.env"
SIGNING_IDENTITY_FILE="$KEYS/signing-identity.txt"
CERT_P12="$KEYS/Certificates.p12"
CERT_PASSWORD_FILE="$KEYS/cert_password.txt"
ENTITLEMENTS="$REPO_ROOT/ci/macos-entitlement.plist"
DO_NOTARIZE=1
DO_INSTALL=0
DO_CLEAN=0
DO_BUILD=1
DO_DMG=1
DO_LAYOUT=1
DO_SIGN=1
NOTARIZE_ONLY=0
SIGNING_KEYCHAIN=""
TEMP_KEYCHAIN_PATH=""
ORIGINAL_DEFAULT_KEYCHAIN=""
CODESIGN_KEYCHAIN_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --no-notarize) DO_NOTARIZE=0 ;;
    --install) DO_INSTALL=1 ;;
    --clean) DO_CLEAN=1 ;;
    --skip-build) DO_BUILD=0 ;;
    --skip-dmg|--app-only) DO_DMG=0 ;;
    --notarize-only)
      NOTARIZE_ONLY=1
      DO_BUILD=0
      DO_LAYOUT=0
      DO_SIGN=0
      DO_DMG=0
      DO_NOTARIZE=1
      ;;
    -h|--help)
      sed -n '1,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

log() { printf "\033[36m[vc-terminal]\033[0m %s\n" "$*"; }
ok() { printf "\033[32m[ ok ]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[warn]\033[0m %s\n" "$*" >&2; }
die() { printf "\033[31m[fail]\033[0m %s\n" "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "$ORIGINAL_DEFAULT_KEYCHAIN" ]]; then
    security default-keychain -d user -s "$ORIGINAL_DEFAULT_KEYCHAIN" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TEMP_KEYCHAIN_PATH" ]]; then
    security delete-keychain "$TEMP_KEYCHAIN_PATH" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

read_trimmed_file() {
  sed -e 's/[[:space:]]*$//' -e '/^$/d' "$1" | head -n1
}

plist_set_string() {
  local plist="$1" key="$2" value="$3"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist" >/dev/null
}

notary_submit() {
  local artifact="$1" log_path="$2"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$artifact" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait \
      --timeout 30m 2>&1 | tee "$log_path"
  else
    [[ -f "$NOTARY_ENV" ]] || die "NOTARY_PROFILE unset and $NOTARY_ENV missing"
    # shellcheck disable=SC1090
    source "$NOTARY_ENV"
    : "${NOTARY_APPLE_ID:?NOTARY_APPLE_ID missing}"
    : "${NOTARY_TEAM_ID:?NOTARY_TEAM_ID missing}"
    : "${NOTARY_PASSWORD:?NOTARY_PASSWORD missing}"
    xcrun notarytool submit "$artifact" \
      --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" \
      --wait \
      --timeout 30m 2>&1 | tee "$log_path"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 missing"
}

prepare_signing_identity() {
  [[ -f "$SIGNING_IDENTITY_FILE" ]] || die "signing identity missing at $SIGNING_IDENTITY_FILE"
  SIGNING_IDENTITY="$(read_trimmed_file "$SIGNING_IDENTITY_FILE")"
  [[ -n "$SIGNING_IDENTITY" ]] || die "signing identity is empty"

  if [[ -f "$CERT_P12" && -f "$CERT_PASSWORD_FILE" ]]; then
    log "Preparing temporary signing keychain from $KEYS"
    local cert_password temp_password existing_keychains
    cert_password="$(read_trimmed_file "$CERT_PASSWORD_FILE")"
    [[ -n "$cert_password" ]] || die "certificate password is empty"
    temp_password="$(uuidgen)"
    TEMP_KEYCHAIN_PATH="$DIST_DIR/$APP_NAME-signing.keychain-db"
    rm -f "$TEMP_KEYCHAIN_PATH"
    existing_keychains="$(security list-keychains -d user | tr -d '"' | tr '\n' ' ')"
    ORIGINAL_DEFAULT_KEYCHAIN="$(security default-keychain -d user 2>/dev/null | tr -d ' "' || true)"

    security create-keychain -p "$temp_password" "$TEMP_KEYCHAIN_PATH"
    security set-keychain-settings -lut 21600 "$TEMP_KEYCHAIN_PATH"
    security unlock-keychain -p "$temp_password" "$TEMP_KEYCHAIN_PATH"
    # Non-interactive launchd sessions often resolve signing identities by
    # default keychain, so make the imported keychain both searchable and default.
    security list-keychains -d user -s "$TEMP_KEYCHAIN_PATH" $existing_keychains >/dev/null
    security default-keychain -d user -s "$TEMP_KEYCHAIN_PATH"
    security import "$CERT_P12" \
      -k "$TEMP_KEYCHAIN_PATH" \
      -P "$cert_password" \
      -T /usr/bin/codesign >/dev/null
    security set-key-partition-list \
      -S apple-tool:,apple:,codesign: \
      -s \
      -k "$temp_password" \
      "$TEMP_KEYCHAIN_PATH" >/dev/null
    security find-identity -v -p codesigning "$TEMP_KEYCHAIN_PATH" | grep -q "$SIGNING_IDENTITY" \
      || die "signing identity not present in temporary keychain"
    SIGNING_KEYCHAIN="$TEMP_KEYCHAIN_PATH"
    CODESIGN_KEYCHAIN_ARGS=(--keychain "$SIGNING_KEYCHAIN")
    ok "temporary signing keychain ready"
    return
  fi

  security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY" \
    || die "signing identity not present in keychain"
  ok "signing identity present"
}

is_macho() {
  file "$1" 2>/dev/null | grep -q 'Mach-O'
}

is_system_load() {
  case "$1" in
    /usr/lib/*|/System/Library/*|@executable_path/*|@loader_path/*|@rpath/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_dylib() {
  local dep="$1"
  if [[ -e "$dep" ]]; then
    printf '%s\n' "$dep"
    return 0
  fi

  local match
  match="$(compgen -G "$dep" | head -n1 || true)"
  if [[ -n "$match" && -e "$match" ]]; then
    printf '%s\n' "$match"
    return 0
  fi

  return 1
}

load_path_for() {
  local consumer="$1" base="$2"
  case "$consumer" in
    "$FRAMEWORKS_DIR"/*) printf '@loader_path/%s\n' "$base" ;;
    *) printf '@executable_path/../Frameworks/%s\n' "$base" ;;
  esac
}

copy_and_rewrite_external_dylibs() {
  log "Bundling non-system Mach-O dependencies"
  mkdir -p "$FRAMEWORKS_DIR"

  local queue=()
  local file dep resolved base dest load_path
  while IFS= read -r -d '' file; do
    queue+=("$file")
  done < <(find "$APP_BUNDLE/Contents/MacOS" -type f -perm -111 -print0)

  local idx=0
  while (( idx < ${#queue[@]} )); do
    file="${queue[$idx]}"
    idx=$((idx + 1))
    is_macho "$file" || continue

    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      is_system_load "$dep" && continue

      resolved="$(resolve_dylib "$dep")" \
        || die "cannot resolve non-system dylib '$dep' referenced by $file"
      base="$(basename "$resolved")"
      dest="$FRAMEWORKS_DIR/$base"
      if [[ ! -e "$dest" ]]; then
        cp "$resolved" "$dest"
        chmod u+w "$dest"
        if is_macho "$dest"; then
          install_name_tool -id "@rpath/$base" "$dest" 2>/dev/null || true
          queue+=("$dest")
        fi
        ok "bundled dylib: $base"
      fi

      load_path="$(load_path_for "$file" "$base")"
      install_name_tool -change "$dep" "$load_path" "$file" \
        || die "failed to rewrite $dep in $file"
    done < <(otool -L "$file" | awk 'NR > 1 {print $1}')
  done
}

assert_no_unbundled_dylibs() {
  log "Validating Mach-O dependency portability"
  local failed=0 file dep
  while IFS= read -r -d '' file; do
    is_macho "$file" || continue
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      if is_system_load "$dep"; then
        continue
      fi
      printf '%s still references non-system dylib: %s\n' "$file" "$dep" >&2
      failed=1
    done < <(otool -L "$file" | awk 'NR > 1 {print $1}')
  done < <(find "$APP_BUNDLE/Contents/MacOS" "$FRAMEWORKS_DIR" -type f -print0 2>/dev/null)

  (( failed == 0 )) || die "non-portable dylib references remain"
  ok "no unbundled Homebrew/MacPorts dylib references"
}

log "Pre-flight checks"
[[ "$(uname -s)" == "Darwin" ]] || die "macOS release pipeline must run on Darwin"
require_cmd codesign
require_cmd xcrun
[[ -f "$ENTITLEMENTS" ]] || die "entitlements missing at $ENTITLEMENTS"

if (( NOTARIZE_ONLY )); then
  [[ -d "$APP_BUNDLE" ]] || die "missing app bundle: $APP_BUNDLE (run make dmg-signed first)"
  [[ -f "$DMG_PATH" ]] || die "missing DMG: $DMG_PATH (run make dmg-signed first)"
  log "Notarize-only mode"
  require_cmd ditto
  APP_ZIP="$DIST_DIR/$APP_NAME.app.zip"
  rm -f "$APP_ZIP"
  /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
  notary_submit "$APP_ZIP" "$DIST_DIR/notary-app.log"
  grep -q "status: Accepted" "$DIST_DIR/notary-app.log" || die "app notarization failed"
  rm -f "$APP_ZIP"
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE" 2>&1 | tail -3
  ok "notarized app"
  notary_submit "$DMG_PATH" "$DIST_DIR/notary-dmg.log"
  grep -q "status: Accepted" "$DIST_DIR/notary-dmg.log" || die "DMG notarization failed"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH" 2>&1 | tail -3
  ok "notarized DMG"
  spctl --assess --type execute --verbose "$APP_BUNDLE" 2>&1 | tail -3 || warn "app spctl assessment did not pass"
  spctl --assess --type open --context context:primary-signature "$DMG_PATH" 2>&1 | tail -3 || warn "DMG spctl assessment did not pass"
  ok "notarize-only complete"
  printf "App: %s\nDMG: %s\n" "$APP_BUNDLE" "$DMG_PATH"
  exit 0
fi

require_cmd cargo
require_cmd file
require_cmd install_name_tool
require_cmd otool
require_cmd tic
require_cmd scdoc
if (( DO_DMG )); then
  require_cmd hdiutil
fi
[[ -f "$APP_TEMPLATE/Contents/Info.plist" ]] || die "macOS bundle skeleton missing at $APP_TEMPLATE"
[[ -f "$APP_TEMPLATE/Contents/Resources/alacritty.icns" ]] || die "alacritty.icns missing; run make icons"
prepare_signing_identity

if (( DO_CLEAN )); then
  log "Cleaning $DIST_DIR"
  rm -rf "$DIST_DIR"
fi
mkdir -p "$DIST_DIR" "$DMG_DIR"

if (( DO_BUILD )); then
  log "Building release binary"
  MACOSX_DEPLOYMENT_TARGET="10.12" cargo build --release
fi

if (( DO_LAYOUT )); then
  log "Laying out $APP_NAME.app"
  rm -rf "$APP_BUNDLE"
  cp -R "$APP_TEMPLATE" "$APP_BUNDLE"
  rm -rf "$APP_BUNDLE/Contents/_CodeSignature"
  mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/completions" "$FRAMEWORKS_DIR"

  # Man pages (same set the upstream `make app` ships)
  scdoc < "$REPO_ROOT/extra/man/alacritty.1.scd" | gzip -c > "$APP_BUNDLE/Contents/Resources/alacritty.1.gz"
  scdoc < "$REPO_ROOT/extra/man/alacritty-msg.1.scd" | gzip -c > "$APP_BUNDLE/Contents/Resources/alacritty-msg.1.gz"
  scdoc < "$REPO_ROOT/extra/man/alacritty.5.scd" | gzip -c > "$APP_BUNDLE/Contents/Resources/alacritty.5.gz"
  scdoc < "$REPO_ROOT/extra/man/alacritty-bindings.5.scd" | gzip -c > "$APP_BUNDLE/Contents/Resources/alacritty-bindings.5.gz"
  scdoc < "$REPO_ROOT/extra/man/alacritty-escapes.7.scd" | gzip -c > "$APP_BUNDLE/Contents/Resources/alacritty-escapes.7.gz"

  # Terminfo + shell completions
  tic -xe alacritty,alacritty-direct -o "$APP_BUNDLE/Contents/Resources" "$REPO_ROOT/extra/alacritty.info"
  cp "$REPO_ROOT/extra/completions/_alacritty" \
     "$REPO_ROOT/extra/completions/alacritty.bash" \
     "$REPO_ROOT/extra/completions/alacritty.fish" \
     "$APP_BUNDLE/Contents/Resources/completions/"

  src="$REPO_ROOT/target/release/alacritty"
  [[ -x "$src" ]] || die "missing release binary $src"
  cp "$src" "$APP_BUNDLE/Contents/MacOS/alacritty"

  copy_and_rewrite_external_dylibs
  assert_no_unbundled_dylibs

  APP_VERSION="$(git -C "$REPO_ROOT" -c core.abbrev=8 show -s --format=%cd-%h --date=format:%Y%m%d-%H%M%S)"
  BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD)"
  COMMIT_FULL="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  BUILD_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  plist="$APP_BUNDLE/Contents/Info.plist"
  plist_set_string "$plist" CFBundleName "$APP_NAME"
  plist_set_string "$plist" CFBundleDisplayName "$APP_NAME"
  plist_set_string "$plist" CFBundleIdentifier "io.vetcoders.vc-terminal"
  plist_set_string "$plist" CFBundleShortVersionString "$APP_VERSION"
  plist_set_string "$plist" CFBundleVersion "$BUILD_NUMBER"
  plist_set_string "$plist" CFBundleGetInfoString "vc-terminal - Vibecrafted. - Agentic Terminal."
  plist_set_string "$plist" VCTerminalBuildCommit "$COMMIT_FULL"
  plist_set_string "$plist" VCTerminalBuildDate "$BUILD_DATE"
  ok "bundle: $APP_BUNDLE"
fi

if (( DO_SIGN )); then
  [[ -d "$APP_BUNDLE" ]] || die "missing app bundle to sign: $APP_BUNDLE"
  log "Signing executables and app"
  if [[ -d "$FRAMEWORKS_DIR" ]]; then
    find "$FRAMEWORKS_DIR" -type f -name '*.dylib' -print0 |
      while IFS= read -r -d '' file; do
        codesign --force \
          "${CODESIGN_KEYCHAIN_ARGS[@]}" \
          --options runtime \
          --sign "$SIGNING_IDENTITY" \
          --timestamp \
          "$file"
      done
  fi
  find "$APP_BUNDLE/Contents/MacOS" -type f -perm -111 -print0 |
    while IFS= read -r -d '' file; do
      codesign --force \
        "${CODESIGN_KEYCHAIN_ARGS[@]}" \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGNING_IDENTITY" \
        --timestamp \
        "$file"
    done
  codesign --force \
    "${CODESIGN_KEYCHAIN_ARGS[@]}" \
    --deep \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    --timestamp \
    "$APP_BUNDLE"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | tail -5
  ok "signed app"
fi

if (( DO_NOTARIZE )); then
  [[ -d "$APP_BUNDLE" ]] || die "missing app for notarization: $APP_BUNDLE"
  log "Notarizing app"
  APP_ZIP="$DIST_DIR/$APP_NAME.app.zip"
  rm -f "$APP_ZIP"
  /usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$APP_ZIP"
  notary_submit "$APP_ZIP" "$DIST_DIR/notary-app.log"
  grep -q "status: Accepted" "$DIST_DIR/notary-app.log" || die "app notarization failed"
  rm -f "$APP_ZIP"
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE" 2>&1 | tail -3
  ok "notarized app"
else
  warn "Skipping app notarization"
fi

if (( DO_DMG )); then
  [[ -d "$APP_BUNDLE" ]] || die "missing app for DMG: $APP_BUNDLE"
  log "Creating DMG at $DMG_PATH"
  rm -f "$DMG_PATH"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$APP_BUNDLE" \
    -ov \
    -format UDZO \
    "$DMG_PATH" 2>&1 | tail -3
  if (( DO_SIGN )); then
    codesign --force "${CODESIGN_KEYCHAIN_ARGS[@]}" --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH" 2>&1 | tail -3
  fi

  if (( DO_NOTARIZE )); then
    log "Notarizing DMG"
    notary_submit "$DMG_PATH" "$DIST_DIR/notary-dmg.log"
    grep -q "status: Accepted" "$DIST_DIR/notary-dmg.log" || die "DMG notarization failed"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH" 2>&1 | tail -3
    ok "notarized DMG"
  else
    warn "Skipping DMG notarization"
  fi
else
  warn "Skipping DMG (--skip-dmg / --app-only)"
fi

if (( DO_INSTALL )); then
  [[ -d "$APP_BUNDLE" ]] || die "missing app to install: $APP_BUNDLE"
  log "Installing $APP_NAME.app into /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP_BUNDLE" /Applications/
  ok "installed /Applications/$APP_NAME.app"
fi

if [[ -d "$APP_BUNDLE" ]]; then
  spctl --assess --type execute --verbose "$APP_BUNDLE" 2>&1 | tail -3 || warn "app spctl assessment did not pass"
fi
if (( DO_DMG )) && [[ -f "$DMG_PATH" ]]; then
  spctl --assess --type open --context context:primary-signature "$DMG_PATH" 2>&1 | tail -3 || warn "DMG spctl assessment did not pass"
fi

ok "release complete"
printf "App: %s\n" "$APP_BUNDLE"
if (( DO_DMG )) && [[ -f "$DMG_PATH" ]]; then
  printf "DMG: %s\n" "$DMG_PATH"
fi
