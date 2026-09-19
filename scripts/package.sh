#!/usr/bin/env bash
#
# Package release DMG:
#   build/pkg/Mimidasu-<version>.dmg   (~35–40 MB; IPADIC model + JMDict lookup
#                        DB bundled, ASR model downloaded on first launch)
#
# Signed with the local self-signed "Mimidasu Dev" certificate (when present) so
# TCC permission grants (Screen Recording) persist across rebuilds; falls
# back to ad-hoc signing otherwise, like scripts/bootstrap.sh. When the
# SIGN_IDENTITY override names a "Developer ID Application" certificate, all
# code is hardened-runtime signed with a trusted timestamp — the notarizable
# shape used by scripts/notarize.sh.
# Launch locally after "Open Anyway" / xattr -cr.
# Usage: scripts/package.sh
#
# Overrides:
#   APP_VERSION     version in the DMG filename (default: MARKETING_VERSION
#                   parsed from project.yml — when not overridden, the same
#                   value the app's Info.plist resolves, so name and bundle
#                   stay in sync)
#   BUILD_NUMBER    CFBundleVersion baked into the build (default: commit
#                   count; falls back to "1" outside a git repo)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build/pkg"
PREFERRED_IDENTITY="Mimidasu Dev"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  : # explicit override wins
elif security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"${PREFERRED_IDENTITY}\""; then
  SIGN_IDENTITY="${PREFERRED_IDENTITY}"
else
  SIGN_IDENTITY="-"
  echo "==> No \"${PREFERRED_IDENTITY}\" certificate found — signing the DMG ad-hoc" >&2
  echo "    (Screen Recording grants will not persist across rebuilds)" >&2
fi

# "Developer ID Application" identities are the notarizable kind: the notary
# service requires the hardened runtime and a trusted timestamp. Older bash
# (3.2) rejects empty arrays under set -u, hence the ${arr[@]+...} guards.
CS_HARDEN=()
if [[ "${SIGN_IDENTITY}" == "Developer ID Application:"* ]]; then
  CS_HARDEN=(--options runtime --timestamp)
  echo "==> Developer ID identity — signing hardened (--options runtime --timestamp)" >&2
fi

# DMG name carries the marketing version; hard-fail rather than ship a
# mislabeled artifact when project.yml cannot be parsed.
APP_VERSION="${APP_VERSION:-$(sed -n 's/^ *MARKETING_VERSION: *"\([^"]*\)".*/\1/p' "${REPO_ROOT}/project.yml" | head -1 || true)}"
if [[ -z "${APP_VERSION}" ]]; then
  echo "ERROR: could not read MARKETING_VERSION from project.yml (or override with APP_VERSION)" >&2
  exit 1
fi
DMG_NAME="Mimidasu-${APP_VERSION}"
echo "==> Version ${APP_VERSION} (DMG: ${DMG_NAME}.dmg)" >&2

# Commit count keeps CFBundleVersion increasing without a state file; "1"
# outside a git repo (package_mas.sh falls back to a timestamp instead).
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "${REPO_ROOT}" rev-list --count HEAD 2>/dev/null || echo 1)}"

source "${REPO_ROOT}/scripts/lib/staging.sh"

cd "${REPO_ROOT}"

command -v xcodegen >/dev/null || { echo "xcodegen required (brew install xcodegen)"; exit 1; }
# Dev hygiene, not a packaging gate (the build below passes its own
# CURRENT_PROJECT_VERSION): a pre-commit-count xcconfig leaves bare Xcode
# builds with a blank CFBundleVersion until bootstrap rewrites it.
if ! grep -qs '^ *CURRENT_PROJECT_VERSION' "${REPO_ROOT}/local/signing.xcconfig"; then
  echo "WARNING: local/signing.xcconfig does not set CURRENT_PROJECT_VERSION —" >&2
  echo "  dev builds get a blank CFBundleVersion. Re-run: scripts/bootstrap.sh --skip-generate" >&2
fi
xcodegen generate

build_app() {
  local scheme="$1" config="$2" out="$3"
  echo "==> Building ${scheme} (${config}, build ${BUILD_NUMBER})"
  xcodebuild -project Mimidasu.xcodeproj -scheme "${scheme}" \
    -configuration "${config}" -destination "generic/platform=macOS" \
    -derivedDataPath "${BUILD_DIR}/derived" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    build
  local built
  built="$(find "${BUILD_DIR}/derived/Build/Products/${config}" -maxdepth 1 -name '*.app' | head -1)"
  rm -rf "${out}"
  mkdir -p "$(dirname "${out}")"
  cp -R "${built}" "${out}"
  # Remove the un-staged build output. It carries no Resources (dictionary
  # data is staged below, only into the copy), and Release builds have no
  # dev-checkout fallback for the bundled dictionary model — launching it
  # instead of the packaged app fails every session start with "Bundled
  # system.dic.zst not found in the app bundle".
  rm -rf "${built}"
}

sign_app() {
  # Sign last: staging (dylibs, README) modifies the bundle after the build,
  # which would otherwise invalidate the seal. Nested dylibs are already
  # signed by stage_runtime; this seals the outer bundle over them. The
  # entitlements must be re-applied here — `codesign --force` without
  # --entitlements would silently drop the sandbox set the Release build
  # embedded, shipping an unsandboxed app.
  codesign --force --sign "${SIGN_IDENTITY}" ${CS_HARDEN[@]+"${CS_HARDEN[@]}"} \
    --entitlements "${REPO_ROOT}/Config/Mimidasu.entitlements" "$1"
}

stage_readme() {
  local app="$1"
  local launch_notes
  if [[ "${SIGN_IDENTITY}" == "Developer ID Application:"* ]]; then
    launch_notes='This app is signed with a Developer ID certificate and notarized
(distributed via scripts/notarize.sh). Just double-click Mimidasu.app to
install — no security workarounds needed.'
  else
    launch_notes='This app is signed with a self-signed local certificate ("Mimidasu Dev").
First launch may be blocked by macOS:
  1. Double-click Mimidasu.app once.
  2. Open System Settings → Privacy & Security → scroll to "Open Anyway".
  3. Or run:  xattr -cr /Applications/Mimidasu.app'
  fi
  cat > "/tmp/mimidasu-launch-notes.txt" <<EOF
Mimidasu — real-time system audio transcriber/translator

${launch_notes}

Compatibility: Apple Silicon, macOS 15.5+.
First run: grant System Audio Recording access (system audio
capture via a Core Audio process tap); one-time
translation language-pack download prompt.

$(cat "${REPO_ROOT}/THIRD_PARTY_NOTICES.md" 2>/dev/null || true)
EOF
  # Append the AGPL text after the heredoc so shell expansion can't touch
  # the license text.
  printf '\n' >> "/tmp/mimidasu-launch-notes.txt"
  cat "${REPO_ROOT}/LICENSE.md" >> "/tmp/mimidasu-launch-notes.txt"
  mkdir -p "${app}/Contents/Resources"
  cp "/tmp/mimidasu-launch-notes.txt" "${app}/Contents/Resources/README.txt"
}

make_dmg() {
  local app="$1" name="$2"
  local staging="${BUILD_DIR}/${name}"
  rm -rf "${staging}" "${BUILD_DIR}/${name}.dmg"
  mkdir -p "${staging}"
  cp -R "${app}" "${staging}/"
  ln -s /Applications "${staging}/Applications"
  # ULMO (lzma) over UDZO (zlib): smaller (~8%) download for the
  # bundled dictionaries + runtime dylibs; mountable on macOS 10.15+.
  hdiutil create -volname "${name}" -srcfolder "${staging}" \
    -format ULMO -ov "${BUILD_DIR}/${name}.dmg"
}

# --- app ---
build_app Mimidasu Release "${BUILD_DIR}/Mimidasu.app"
stage_runtime "${BUILD_DIR}/Mimidasu.app"
stage_notices "${BUILD_DIR}/Mimidasu.app" LICENSE.md
stage_readme "${BUILD_DIR}/Mimidasu.app"
sign_app "${BUILD_DIR}/Mimidasu.app"
make_dmg "${BUILD_DIR}/Mimidasu.app" "${DMG_NAME}"

echo
echo "Artifacts in ${BUILD_DIR}:"
ls -lh "${BUILD_DIR}" | grep dmg || true
echo "Launch ${BUILD_DIR}/Mimidasu.app (or install the DMG) — not the derived build output."
