#!/usr/bin/env bash
#
# Release DMG: package + notarize → build/pkg/Mimidasu.dmg
#
#   scripts/release.sh
#
# Runs scripts/package.sh with a "Developer ID Application" identity (all
# code hardened-runtime signed with a trusted timestamp), submits the DMG to
# Apple's notary service, staples the ticket onto it, and validates the
# result — recipients install by double-clicking, no "Open Anyway" step.
#
# One-time setup:
#   1. "Developer ID Application" certificate in the keychain — created at
#      developer.apple.com → Certificates (the CSR's private key must stay
#      in that keychain, or codesigning fails).
#   2. Notary credentials profile:
#        xcrun notarytool store-credentials mimidasu-notary \
#          --apple-id YOU@example.com --team-id TEAMID
#      (app-specific password from appleid.apple.com — or the App Store
#      Connect API-key equivalent: --key/--key-id/--issuer)
#
# Overrides:
#   SIGN_IDENTITY   verbatim identity (must be a Developer ID Application cert)
#   NOTARY_PROFILE  keychain profile name (default: mimidasu-notary)
#   SKIP_PACKAGE=1  reuse the existing build/pkg/Mimidasu.dmg

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG="${REPO_ROOT}/build/pkg/Mimidasu.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-mimidasu-notary}"

cd "${REPO_ROOT}"

# 1. Signing identity — a notarizable "Developer ID Application" certificate.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
fi
if [[ -z "${SIGN_IDENTITY}" || "${SIGN_IDENTITY}" != "Developer ID Application:"* ]]; then
  echo "ERROR: no \"Developer ID Application\" certificate found in the keychain." >&2
  echo "  Create one: developer.apple.com → Certificates → + → Developer ID Application" >&2
  echo "  (or override with: SIGN_IDENTITY=\"Developer ID Application: …\" $0)" >&2
  exit 1
fi
export SIGN_IDENTITY
echo "==> Signing with ${SIGN_IDENTITY}"

# 2. Notary credentials preflight — proves the profile (and network) work
#    before spending minutes on the build. history is the cheapest call.
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  echo "ERROR: notarytool credentials profile \"${NOTARY_PROFILE}\" not found or rejected." >&2
  echo "  Store credentials with:" >&2
  echo "    xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id YOU@example.com --team-id TEAMID" >&2
  echo "  (or override with: NOTARY_PROFILE=<profile> $0)" >&2
  exit 1
fi

# 3. Build, stage, harden-sign, DMG — package.sh handles all of it once the
#    identity is a Developer ID one (hardened runtime + timestamp follow).
if [[ "${SKIP_PACKAGE:-0}" != "1" ]]; then
  scripts/package.sh
elif [[ ! -f "${DMG}" ]]; then
  echo "ERROR: SKIP_PACKAGE=1 but ${DMG} does not exist." >&2
  exit 1
fi

fetch_notary_log() {
  # Pull the per-file violation report for a failed submission, so the
  # reason ("invalid signature", "hardened runtime missing", …) is visible.
  local id
  id="$(printf '%s' "$1" | grep -o '"id" *: *"[^"]*"' | head -1 | sed 's/.*"id" *: *"//;s/"$//' || true)"
  if [[ -n "${id}" ]]; then
    echo "==> Fetching notary log ${id}" >&2
    xcrun notarytool log "${id}" --keychain-profile "${NOTARY_PROFILE}" >&2 || true
  fi
}

# 4. Submit and wait for the verdict (minutes; progress streams on stderr).
echo "==> Notarizing ${DMG}"
submit_json=""
if ! submit_json="$(xcrun notarytool submit "${DMG}" \
    --keychain-profile "${NOTARY_PROFILE}" --wait --output-format json)"; then
  echo "ERROR: notarization submission failed." >&2
  fetch_notary_log "${submit_json}"
  exit 1
fi
if ! printf '%s' "${submit_json}" | grep -q '"status" *: *"Accepted"'; then
  echo "ERROR: notarization was not accepted:" >&2
  printf '  %s\n' "${submit_json}" >&2
  fetch_notary_log "${submit_json}"
  exit 1
fi

# 5. Attach the ticket and verify the whole chain offline.
echo "==> Stapling ${DMG}"
xcrun stapler staple "${DMG}"
echo "==> Validating"
xcrun stapler validate "${DMG}"

echo
echo "Notarized release ready: ${DMG}"
