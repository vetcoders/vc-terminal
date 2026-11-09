#!/usr/bin/env bash
# Standalone macOS packaging, adapted from 2860329a^.
# Build -> app + private resources/dylibs -> sign -> optional signed DMG.
# This local path neither notarizes nor installs the app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="${DIST_DIR:-$REPO_ROOT/dist}"
CARGO="${CARGO:-cargo}"
DO_BUILD=1
DO_DMG=1
for arg in "$@"; do
  case "$arg" in
    --skip-build) DO_BUILD=0 ;;
    --skip-dmg|--app-only) DO_DMG=0 ;;
    --no-notarize) ;; # Compatibility with the recovered local-build invocation.
    -h|--help)
      printf 'Usage: %s [--skip-build] [--skip-dmg]\n' "$0"
      printf 'Outputs: DIST_DIR/vc-terminal.app and DIST_DIR/vc-terminal.dmg (default: repo/dist).\n'
      printf 'Developer ID team MW223P3NPX when available, otherwise ad-hoc. No notarization or install.\n'
      exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

log() { printf '[vc-terminal] %s\n' "$*"; }
ok() { log "$*"; }
die() { printf '[vc-terminal] %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 missing"; }

[[ "$(uname -s)" == Darwin ]] || die 'macOS packaging requires Darwin'
for cmd in "$CARGO" python3 codesign security file install_name_tool otool tic scdoc; do
  require_cmd "$cmd"
done
if (( DO_DMG )); then require_cmd hdiutil; fi
cd "$REPO_ROOT"
APP_TEMPLATE="$REPO_ROOT/extra/osx/vc-terminal.app"
ENTITLEMENTS="$REPO_ROOT/extra/osx/vc-terminal.entitlements"
FONT_DIR="$REPO_ROOT/assets/fonts/source-code-pro"
[[ -f "$APP_TEMPLATE/Contents/Resources/alacritty.icns" ]] || die 'bundle icon missing; run make icons'
[[ -f "$ENTITLEMENTS" ]] || die 'entitlements missing'

# Read the native Cargo output directory as well as the package version.
metadata="$("$CARGO" metadata --no-deps --format-version=1)"
APP_VERSION="$(printf '%s' "$metadata" | python3 -c 'import json,sys; print(next(p["version"] for p in json.load(sys.stdin)["packages"] if p["name"] == "alacritty"))')"
TARGET_DIR="$(printf '%s' "$metadata" | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
if (( DO_BUILD )); then
  make --no-print-directory -C "$REPO_ROOT" release-bins CARGO="$CARGO"
fi
BINARY="$TARGET_DIR/release/alacritty"
[[ -x "$BINARY" ]] || die "missing release binary: $BINARY"
COMMIT_FULL="$(git rev-parse HEAD)"
COMMIT_SHORT="$(git rev-parse --short HEAD)"
VERSION_OUTPUT="$("$BINARY" --version)"
[[ "$VERSION_OUTPUT" == "alacritty $APP_VERSION ($COMMIT_SHORT)" ]] \
  || die "binary does not match Cargo version and HEAD: $VERSION_OUTPUT (rebuild release-bins)"

# Use only the existing Developer ID keychain identity; never import keys or
# change the user's keychain search list. Signing failure is fatal.
SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk '/"Developer ID Application: .*\(MW223P3NPX\)"/ {print $2; exit}')"
SIGN_ARGS=(--force --options runtime)
if [[ -n "$SIGNING_IDENTITY" ]]; then
  SIGN_ARGS+=(--sign "$SIGNING_IDENTITY" --timestamp)
  log "Signing with Developer ID team MW223P3NPX ($SIGNING_IDENTITY)"
else
  SIGN_ARGS+=(--sign - --timestamp=none)
  log 'No Developer ID team MW223P3NPX available; signing ad-hoc'
fi

mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
STAGING_DIR="$(mktemp -d "$DIST_DIR/.vc-terminal.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_BUNDLE="$STAGING_DIR/vc-terminal.app"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
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
          install_name_tool -id "@rpath/$base" "$dest"
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


log 'Laying out standalone vc-terminal.app'
cp -R "$APP_TEMPLATE" "$APP_BUNDLE"
rm -rf "$APP_BUNDLE/Contents/_CodeSignature"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/completions" "$FRAMEWORKS_DIR"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/vc-terminal"
for manpage in "$REPO_ROOT"/extra/man/*.scd; do
  scdoc < "$manpage" | gzip -c > "$APP_BUNDLE/Contents/Resources/$(basename "${manpage%.scd}").gz"
done
tic -xe alacritty,alacritty-direct -o "$APP_BUNDLE/Contents/Resources" "$REPO_ROOT/extra/alacritty.info"
cp "$REPO_ROOT"/extra/completions/{_alacritty,alacritty.bash,alacritty.fish} "$APP_BUNDLE/Contents/Resources/completions/"
mkdir -p "$APP_BUNDLE/Contents/Resources/fonts/source-code-pro"
cp "$FONT_DIR"/*.ttf "$FONT_DIR/OFL.txt" "$APP_BUNDLE/Contents/Resources/fonts/source-code-pro/"

python3 - "$APP_BUNDLE/Contents/Info.plist" "$APP_VERSION" "$COMMIT_FULL" <<'PLIST'
import datetime, plistlib, subprocess, sys
path, version, commit = sys.argv[1:]
with open(path, 'rb') as f:
    plist = plistlib.load(f)
plist.update(
    CFBundleExecutable='vc-terminal',
    CFBundleIdentifier='io.vetcoders.vc-terminal',
    CFBundleShortVersionString=version,
    CFBundleVersion=subprocess.check_output(['git', 'rev-list', '--count', 'HEAD'], text=True).strip(),
    ATSApplicationFontsPath='fonts/source-code-pro',
    VCTerminalBuildCommit=commit,
    VCTerminalBuildDate=datetime.datetime.now(datetime.timezone.utc).isoformat(),
)
with open(path, 'wb') as f:
    plistlib.dump(plist, f, sort_keys=False)
PLIST
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
copy_and_rewrite_external_dylibs
assert_no_unbundled_dylibs

while IFS= read -r -d '' dylib; do
  codesign "${SIGN_ARGS[@]}" "$dylib"
done < <(find "$FRAMEWORKS_DIR" -type f -name '*.dylib' -print0)
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE/Contents/MacOS/vc-terminal"
codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
[[ "$("$APP_BUNDLE/Contents/MacOS/vc-terminal" --version)" == "$VERSION_OUTPUT" ]] \
  || die 'packaged binary version changed'

if (( DO_DMG )); then
  DMG_STAGING="$STAGING_DIR/dmg"
  mkdir -p "$DMG_STAGING"
  cp -R "$APP_BUNDLE" "$DMG_STAGING/"
  ln -s /Applications "$DMG_STAGING/Applications"
  hdiutil create -volname vc-terminal -srcfolder "$DMG_STAGING" -ov -format UDZO "$STAGING_DIR/vc-terminal.dmg"
  codesign "${SIGN_ARGS[@]}" "$STAGING_DIR/vc-terminal.dmg"
  codesign --verify --verbose=2 "$STAGING_DIR/vc-terminal.dmg"
fi

# Only replace the previous local artifact after all requested stages passed.
rm -rf "$DIST_DIR/vc-terminal.app"
mv "$APP_BUNDLE" "$DIST_DIR/vc-terminal.app"
printf 'App: %s\n' "$DIST_DIR/vc-terminal.app"
if (( DO_DMG )); then
  mv -f "$STAGING_DIR/vc-terminal.dmg" "$DIST_DIR/vc-terminal.dmg"
  printf 'DMG: %s\n' "$DIST_DIR/vc-terminal.dmg"
fi
log 'Local packaging complete (not notarized, not installed)'
