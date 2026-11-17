#!/bin/bash
# Builds, signs, notarizes and publishes a SwipeSay release, then updates the Sparkle appcast.
#
# Usage:
#   scripts/release.sh <version> --notes <notes.md> [--dry-run]
#
#   <version>     Marketing version, for example 0.2.0. It must be greater than the current one.
#                 The build number (CFBundleVersion) is bumped by one automatically.
#   --notes FILE  Release notes in Markdown, used for both the GitHub Release and the Sparkle update window.
#   --dry-run     Do everything except publishing: no commit, tag, push or GitHub Release.
#                 project.yml is restored afterwards. Output stays in build/release/.
#
# Environment:
#   NOTARY_PROFILE   notarytool keychain profile (required), created with `xcrun notarytool store-credentials`
#   SIGN_IDENTITY    default "Developer ID Application"
#   TEAM_ID          default UBS9FUBNFR. Must never change, or users lose permissions and keychain access.
#   SPARKLE_ACCOUNT  keychain account of the EdDSA update key, default "swipesay"
set -euo pipefail

REPO="jiaqianjing/SwipeSay"
BUNDLE_ID="com.kenjia.swipesay"
TEAM_ID="${TEAM_ID:-UBS9FUBNFR}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-swipesay}"
MIN_MACOS="14.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
cd "$ROOT"

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

# ---------- arguments ----------
VERSION="" NOTES="" DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) [ -z "$VERSION" ] || die "unexpected argument $1"; VERSION="$1"; shift ;;
  esac
done
[ -n "$VERSION" ] || die "missing <version> (see --help)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.2.3"
[ -n "${NOTARY_PROFILE:-}" ] || die "set NOTARY_PROFILE to your notarytool keychain profile"
if [ "$DRY_RUN" -eq 0 ]; then
  [ -n "$NOTES" ] && [ -f "$NOTES" ] || die "--notes <file> is required for a real release"
fi
for tool in xcodegen xcodebuild xcrun gh python3 hdiutil; do command -v "$tool" >/dev/null || die "$tool not found"; done

# ---------- preflight ----------
step "Preflight"
if [ "$DRY_RUN" -eq 0 ]; then
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "releases are cut from main"
  [ -z "$(git status --porcelain)" ] || die "working tree is not clean"
  git fetch -q origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "main is not in sync with origin/main"
  ! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "tag v$VERSION already exists"
fi

CUR_VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
CUR_BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml)
[ -n "$CUR_VERSION" ] && [ -n "$CUR_BUILD" ] || die "could not read versions from project.yml"
python3 -I -c 'import sys; a=tuple(map(int,sys.argv[1].split("."))); b=tuple(map(int,sys.argv[2].split("."))); sys.exit(0 if a>b else 1)' \
  "$VERSION" "$CUR_VERSION" || die "version $VERSION must be greater than $CUR_VERSION"
BUILD=$((CUR_BUILD + 1))
echo "version $CUR_VERSION ($CUR_BUILD) -> $VERSION ($BUILD)"
security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY.*($TEAM_ID)" || die "no \"$SIGN_IDENTITY\" identity for team $TEAM_ID"

# Dry runs put project.yml back afterwards.
if [ "$DRY_RUN" -eq 1 ]; then
  cp project.yml "$ROOT/build/.project.yml.bak" 2>/dev/null || { mkdir -p "$ROOT/build"; cp project.yml "$ROOT/build/.project.yml.bak"; }
  restore() { mv "$ROOT/build/.project.yml.bak" "$ROOT/project.yml"; xcodegen generate -q >/dev/null 2>&1 || true; }
  trap restore EXIT
fi

# ---------- bump ----------
step "Bump version"
sed -i '' "s/^\( *MARKETING_VERSION: \)\".*\"/\1\"$VERSION\"/; s/^\( *CURRENT_PROJECT_VERSION: \)\".*\"/\1\"$BUILD\"/" project.yml
xcodegen generate -q

# ---------- build ----------
step "Archive (Release, Universal)"
mkdir -p "$OUT"
ARCHIVE="$OUT/SwipeSay.xcarchive"
EXPORT="$OUT/export"
rm -rf "${ARCHIVE:?}" "${EXPORT:?}"
xcodebuild -project SwipeSay.xcodeproj -scheme SwipeSay -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath "$OUT/dd" archive \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" -quiet

step "Export with Developer ID (re-signs Sparkle's helpers for notarization)"
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$SIGN_IDENTITY</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$OUT/ExportOptions.plist" -quiet
APP="$EXPORT/SwipeSay.app"
[ -d "$APP" ] || die "export did not produce SwipeSay.app"

step "Verify signature and identity"
codesign --verify --deep --strict "$APP"
SIGN_INFO=$(codesign -dvv "$APP" 2>&1)
grep -q "^Identifier=$BUNDLE_ID$" <<<"$SIGN_INFO" || die "bundle identifier changed"
grep -q "^TeamIdentifier=$TEAM_ID$" <<<"$SIGN_INFO" || die "team identifier changed"
grep -q "flags=.*runtime" <<<"$SIGN_INFO" || die "hardened runtime is off"
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
PLIST_BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
[ "$PLIST_VERSION" = "$VERSION" ] && [ "$PLIST_BUILD" = "$BUILD" ] || die "Info.plist has $PLIST_VERSION ($PLIST_BUILD)"
/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$APP/Contents/Info.plist" >/dev/null || die "SUPublicEDKey missing"
echo "ok: $BUNDLE_ID $PLIST_VERSION ($PLIST_BUILD), team $TEAM_ID, $(lipo -archs "$APP/Contents/MacOS/SwipeSay")"

# ---------- notarize ----------
notarize() { # file
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m | tee "$OUT/notary.log" | tail -3
  grep -q "status: Accepted" "$OUT/notary.log" || die "notarization of $(basename "$1") was not accepted"
}

step "Notarize the app"
rm -f "$OUT/SwipeSay-app.zip"
ditto -c -k --keepParent "$APP" "$OUT/SwipeSay-app.zip"
notarize "$OUT/SwipeSay-app.zip"
xcrun stapler staple -q "$APP"

step "Build, sign and notarize the DMG"
DMG="$OUT/SwipeSay-$VERSION.dmg"
STAGE="$OUT/dmgroot"
rm -rf "${STAGE:?}" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/SwipeSay.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "SwipeSay $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" -quiet
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
notarize "$DMG"
xcrun stapler staple -q "$DMG"
spctl -a -t install "$DMG" 2>&1 | grep -q accepted || spctl -a -vv -t install "$DMG"
spctl -a -vv -t install "$DMG" 2>&1 | grep -q "Notarized Developer ID" || die "Gatekeeper does not report Notarized Developer ID"

# ---------- Sparkle ----------
step "Sign the update for Sparkle"
SPARKLE_BIN="$OUT/dd/SourcePackages/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/sign_update" ] || die "Sparkle tools not found in $SPARKLE_BIN"
ED_ATTRS=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")
[[ "$ED_ATTRS" == *'sparkle:edSignature='* ]] || die "sign_update failed: $ED_ATTRS"

step "Update appcast.xml"
NOTES_HTML="$OUT/notes.html"
if [ -n "$NOTES" ]; then
  python3 -I -c 'import json,sys; print(json.dumps({"text": open(sys.argv[1]).read(), "mode": "markdown"}))' "$NOTES" \
    | gh api markdown --input - > "$NOTES_HTML"
else
  echo "<p>Dry run.</p>" > "$NOTES_HTML"
fi
APPCAST="$ROOT/appcast.xml"
[ "$DRY_RUN" -eq 1 ] && { cp "$APPCAST" "$OUT/appcast.xml" 2>/dev/null || true; APPCAST="$OUT/appcast.xml"; }
python3 -I "$ROOT/scripts/appcast.py" "$APPCAST" \
  --version "$VERSION" --build "$BUILD" --min-macos "$MIN_MACOS" \
  --url "https://github.com/$REPO/releases/download/v$VERSION/SwipeSay-$VERSION.dmg" \
  --ed-attrs "$ED_ATTRS" --notes-html "$NOTES_HTML"
echo "appcast: $APPCAST"

if [ "$DRY_RUN" -eq 1 ]; then
  step "Dry run finished: nothing was committed, tagged or published"
  echo "DMG:     $DMG"
  echo "appcast: $APPCAST"
  exit 0
fi

# ---------- publish ----------
# Order matters: the tag and the GitHub Release (with the DMG) go up first, the appcast last, so
# clients never see an update whose download doesn't exist yet.
step "Commit version bump and tag v$VERSION"
git add project.yml SwipeSay.xcodeproj
git commit -q -m "Release v$VERSION"
git tag -a "v$VERSION" -m "SwipeSay $VERSION"
git push -q origin main "v$VERSION"

step "Create GitHub Release"
gh release create "v$VERSION" "$DMG" --repo "$REPO" --title "SwipeSay $VERSION" --notes-file "$NOTES" --verify-tag

step "Publish appcast"
git add appcast.xml
git commit -q -m "Update appcast for v$VERSION"
git push -q origin main

step "Verify the published update"
sleep 5
curl -fsSL "https://github.com/$REPO/releases/download/v$VERSION/SwipeSay-$VERSION.dmg" -o "$OUT/downloaded.dmg"
cmp -s "$DMG" "$OUT/downloaded.dmg" && echo "ok: release asset matches the local DMG" || die "downloaded DMG differs"
echo "Done: SwipeSay $VERSION ($BUILD) is live. The raw appcast may take a few minutes to refresh."
