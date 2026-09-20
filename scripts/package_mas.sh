#!/usr/bin/env bash
#
# Mac App Store package: build the sandboxed Release app, stage the runtime,
# sign everything with the "Apple Distribution" identity, embed the App Store
# provisioning profile, and produce a .pkg for App Store Connect.
#
#   scripts/package_mas.sh
#
# Output: build/mas/Mimidasu.app and build/mas/Mimidasu.pkg
#
# Unlike scripts/package.sh (DMG), this path hard-fails when any runtime
# artifact is missing — a MAS build that falls back to the mock transcriber is
# a Guideline 2.1 rejection, never a shippable artifact.
#
# One-time prerequisites (see APP_STORE.md §F):
#   - App ID `mimidasu.app` with the App Sandbox capability
#   - "Apple Distribution" certificate in the keychain
#   - Mac App Store provisioning profile at
#     local/profiles/Mimidasu_AppStore.provisionprofile
#   - "3rd Party Mac Developer Installer" certificate in the keychain to sign
#     the .pkg (the app itself signs with "Apple Distribution")
#
# Overrides:
#   MAS_IDENTITY   verbatim "Apple Distribution: …" identity
#   MAS_PROFILE    path to the .provisionprofile
#   BUILD_NUMBER   CFBundleVersion for this upload (default: commit count)
#   SKIP_PKG=1     stop after the signed .app

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build/mas"
APP="${BUILD_DIR}/Mimidasu.app"
PKG="${BUILD_DIR}/Mimidasu.pkg"
BUNDLE_ID="mimidasu.app"
ENTITLEMENTS="${REPO_ROOT}/Config/Mimidasu.entitlements"
MAS_PROFILE="${MAS_PROFILE:-${REPO_ROOT}/local/profiles/Mimidasu_AppStore.provisionprofile}"

# App Store Connect rejects re-uploads of the same CFBundleVersion and wants
# increasing integers; the commit count is monotonic without a state file
# (UTC-timestamp fallback outside a git repo). Uploads before 2026-09 used a
# timestamp default: if any of those reached App Store Connect, pin an
# explicit BUILD_NUMBER greater than the old value until the count catches
# up. History rewrites regress the count too — pin one after those.
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "${REPO_ROOT}" rev-list --count HEAD 2>/dev/null || date -u +%Y%m%d%H%M)}"

source "${REPO_ROOT}/scripts/lib/staging.sh"

cd "${REPO_ROOT}"

command -v xcodegen >/dev/null || { echo "xcodegen required (brew install xcodegen)"; exit 1; }

# --- signing identity -------------------------------------------------------
if [[ -z "${MAS_IDENTITY:-}" ]]; then
  MAS_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Apple Distribution: [^"]*"' | head -1 | tr -d '"' || true)"
fi
if [[ -z "${MAS_IDENTITY}" || "${MAS_IDENTITY}" != "Apple Distribution:"* ]]; then
  echo "ERROR: no \"Apple Distribution\" certificate found in the keychain." >&2
  echo "  Create one: developer.apple.com → Certificates → + → Apple Distribution" >&2
  echo "  (or override with: MAS_IDENTITY=\"Apple Distribution: …\" $0)" >&2
  exit 1
fi
echo "==> Signing with ${MAS_IDENTITY}"

# --- provisioning profile ---------------------------------------------------
if [[ ! -f "${MAS_PROFILE}" ]]; then
  echo "ERROR: provisioning profile not found at ${MAS_PROFILE}" >&2
  echo "  Download a Mac App Store profile for ${BUNDLE_ID} (see APP_STORE.md §F.3)" >&2
  exit 1
fi
PROFILE_PLIST="$(mktemp -t mimidasu-profile)"
MERGED_ENTITLEMENTS="$(mktemp -t mimidasu-entitlements)"
trap 'rm -f "${PROFILE_PLIST}" "${MERGED_ENTITLEMENTS}"' EXIT
security cms -D -i "${MAS_PROFILE}" > "${PROFILE_PLIST}" 2>/dev/null

TEAM_ID="$(plutil -extract TeamIdentifier.0 raw -o - "${PROFILE_PLIST}")"
# The entitlement key itself contains dots, which plutil's keypath syntax
# would treat as separators — read it with plistlib instead.
PROFILE_APP_ID="$(python3 -c 'import plistlib, sys
print(plistlib.load(open(sys.argv[1], "rb"))["Entitlements"]["com.apple.application-identifier"])' "${PROFILE_PLIST}")"
if [[ "${PROFILE_APP_ID}" != "${TEAM_ID}.${BUNDLE_ID}" ]]; then
  echo "ERROR: profile authorizes ${PROFILE_APP_ID}, expected ${TEAM_ID}.${BUNDLE_ID}" >&2
  exit 1
fi
echo "==> Profile: $(basename "${MAS_PROFILE}") (team ${TEAM_ID})"

# Xcode normally merges the profile's entitlements with the target's at signing
# time; signing by hand means doing it here. Start from the profile's set
# (application-identifier, team-identifier, keychain groups) and add the
# sandbox entitlements the app needs.
if [[ ! -f "${ENTITLEMENTS}" ]]; then
  echo "ERROR: ${ENTITLEMENTS} missing" >&2
  exit 1
fi
plutil -extract Entitlements xml1 -o "${MERGED_ENTITLEMENTS}" "${PROFILE_PLIST}"
while IFS= read -r key; do
  /usr/libexec/PlistBuddy -c "Set :${key} true" "${MERGED_ENTITLEMENTS}" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :${key} bool true" "${MERGED_ENTITLEMENTS}"
done < <(python3 -c 'import plistlib, sys
with open(sys.argv[1], "rb") as f:
    d = plistlib.load(f)
print("\n".join(k for k, v in d.items() if k.startswith("com.apple.security.") and v is True))' "${ENTITLEMENTS}")

# --- build (unsigned; signing happens after staging) ------------------------
require_runtime_artifacts

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building Mimidasu (Release, build ${BUILD_NUMBER})"
rm -rf "${BUILD_DIR}"
xcodebuild -project Mimidasu.xcodeproj -scheme Mimidasu \
  -configuration Release -destination "generic/platform=macOS" \
  -derivedDataPath "${BUILD_DIR}/derived" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  CODE_SIGNING_ALLOWED=NO \
  build

built="$(find "${BUILD_DIR}/derived/Build/Products/Release" -maxdepth 1 -name '*.app' | head -1)"
[[ -n "${built}" ]] || { echo "ERROR: build produced no .app" >&2; exit 1; }
mkdir -p "${BUILD_DIR}"
rm -rf "${APP}"
cp -R "${built}" "${APP}"
rm -rf "${built}"

# --- stage, embed profile, sign --------------------------------------------
SIGN_IDENTITY="${MAS_IDENTITY}"
CS_HARDEN=(--timestamp)
echo "==> Staging runtime"
stage_runtime "${APP}"
stage_notices "${APP}" LICENSE-MAS.md

# The embedded profile authorizes the sandbox entitlements at launch; it must
# be in place before the outer bundle is sealed.
cp -f "${MAS_PROFILE}" "${APP}/Contents/embedded.provisionprofile"
# Browser-downloaded profiles carry com.apple.quarantine, which App Store
# upload validation rejects anywhere inside the package — strip it before the
# outer bundle is sealed, then gate on it after signing.
strip_quarantine "${APP}"

echo "==> Signing app bundle"
codesign --force --sign "${MAS_IDENTITY}" --timestamp \
  --entitlements "${MERGED_ENTITLEMENTS}" "${APP}"
codesign --verify --deep --strict "${APP}"
require_no_quarantine "${APP}"

echo
echo "==> Entitlements on the signed app:"
codesign -d --entitlements :- "${APP}" 2>/dev/null | plutil -p - 2>/dev/null || true

if [[ "${SKIP_PKG:-0}" == "1" ]]; then
  echo
  echo "SKIP_PKG=1 — signed app ready: ${APP}"
  exit 0
fi

# --- installer package ------------------------------------------------------
# The .pkg must be signed with a Mac App Store installer identity; it cannot be
# uploaded unsigned. Warn rather than fail so the signed app is still produced
# when the installer certificate is not yet installed.
# No `-p codesigning` here: installer-signing identities are a distinct kind,
# and that filter excludes them (Apple: "Don't use the -p codesigning option
# to filter for code-signing identities").
INSTALLER_IDENTITY="$(security find-identity -v 2>/dev/null \
  | grep -oE '"(3rd Party Mac Developer Installer|Mac Installer Distribution): [^"]*"' \
  | head -1 | tr -d '"' || true)"
rm -f "${PKG}"
if [[ -n "${INSTALLER_IDENTITY}" ]]; then
  echo "==> Building installer package (signed with ${INSTALLER_IDENTITY})"
  productbuild --component "${APP}" /Applications --sign "${INSTALLER_IDENTITY}" "${PKG}"
else
  echo "WARNING: no Mac App Store installer certificate found in the keychain." >&2
  echo "  Create one: developer.apple.com → Certificates → + → Mac Installer Distribution" >&2
  echo "  Writing an UNSIGNED ${PKG} — it cannot be uploaded until signed." >&2
  productbuild --component "${APP}" /Applications "${PKG}"
fi

echo
echo "Artifacts in ${BUILD_DIR}:"
ls -lh "${APP}" "${PKG}" 2>/dev/null | sed 's/^/  /'
echo
echo "Upload ${PKG} with the Transporter app (or 'xcrun altool --upload-app')."
