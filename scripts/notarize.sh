#!/usr/bin/env bash
#
# Release DMG: package + notarize → build/pkg/Mimidasu-<version>.dmg
#
#   scripts/notarize.sh
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
#   NOTARY_PROFILE  keychain profile name (default: mimidasu-notary; falls back
#                   to the legacy "mimi-notary" profile when the default is absent)
#   APP_VERSION     version in the DMG filename (default: MARKETING_VERSION
#                   parsed from project.yml — forwarded to scripts/package.sh)
#   SKIP_PACKAGE=1  reuse the existing build/pkg/Mimidasu-<version>.dmg

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# package.sh names the DMG after the marketing version; resolve the same value
# here (and forward it) so SKIP_PACKAGE=1 finds the artifact package.sh made.
APP_VERSION="${APP_VERSION:-$(sed -n 's/^ *MARKETING_VERSION: *"\([^"]*\)".*/\1/p' "${REPO_ROOT}/project.yml" | head -1 || true)}"
if [[ -z "${APP_VERSION}" ]]; then
  echo "ERROR: could not read MARKETING_VERSION from project.yml (or override with APP_VERSION)" >&2
  exit 1
fi
export APP_VERSION
DMG="${REPO_ROOT}/build/pkg/Mimidasu-${APP_VERSION}.dmg"
# The Mimi → Mimidasu rename changed the default profile name; a pre-rename
# "mimi-notary" profile still works, so fall back to it when the new default
# is absent (mirrors the legacy "Mimidasu Dev" signing fallback in bootstrap.sh).
DEFAULT_NOTARY_PROFILE="mimidasu-notary"
LEGACY_NOTARY_PROFILE="mimi-notary"
NOTARY_PROFILE="${NOTARY_PROFILE:-${DEFAULT_NOTARY_PROFILE}}"

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
  # Only fall back when the caller did not name a profile explicitly.
  if [[ "${NOTARY_PROFILE}" == "${DEFAULT_NOTARY_PROFILE}" ]] \
      && xcrun notarytool history --keychain-profile "${LEGACY_NOTARY_PROFILE}" >/dev/null 2>&1; then
    echo "==> Profile \"${DEFAULT_NOTARY_PROFILE}\" not found — using legacy \"${LEGACY_NOTARY_PROFILE}\"" >&2
    NOTARY_PROFILE="${LEGACY_NOTARY_PROFILE}"
  else
    echo "ERROR: notarytool credentials profile \"${NOTARY_PROFILE}\" not found or rejected." >&2
    echo "  Store credentials with:" >&2
    echo "    xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id YOU@example.com --team-id TEAMID" >&2
    echo "  (or override with: NOTARY_PROFILE=<profile> $0)" >&2
    exit 1
  fi
fi

# 3. Build, stage, harden-sign, styled DMG — package.sh handles all of it
#    once the identity is a Developer ID one (hardened runtime + timestamp
#    follow). The Finder background bakes in there, before the submission
#    below — never re-style after stapling.
if [[ "${SKIP_PACKAGE:-0}" != "1" ]]; then
  scripts/package.sh
elif [[ ! -f "${DMG}" ]]; then
  echo "ERROR: SKIP_PACKAGE=1 but ${DMG} does not exist." >&2
  exit 1
fi

fetch_notary_log() {
  # Pull the per-file violation report for a failed submission, so the
  # reason ("invalid signature", "hardened runtime missing", …) is visible.
  local id="$1"
  if [[ -n "${id}" ]]; then
    echo "==> Fetching notary log ${id}" >&2
    xcrun notarytool log "${id}" --keychain-profile "${NOTARY_PROFILE}" >&2 || true
  fi
}

poll_notary_status() {
  # {"status": "..."} from the submission-info call; empty when the poll
  # itself failed (transient network hiccups happen — callers retry).
  xcrun notarytool info "$1" --keychain-profile "${NOTARY_PROFILE}" \
    --output-format json 2>/dev/null \
    | grep -o '"status" *: *"[^"]*"' | head -1 \
    | sed 's/.*"status" *: *"//;s/"$//' || true
}

# 4. Submit, then poll for the verdict. notarytool --wait is fully silent
#    while Apple processes (often 5–30 minutes), so submit for an id up
#    front and poll the status with visible elapsed-time progress.
echo "==> Notarizing ${DMG}"
echo "==> Uploading to Apple (no output until the upload finishes)"
submit_json=""
if ! submit_json="$(xcrun notarytool submit "${DMG}" \
    --keychain-profile "${NOTARY_PROFILE}" --output-format json)"; then
  echo "ERROR: notarization submission failed." >&2
  printf '  %s\n' "${submit_json}" >&2
  exit 1
fi
SUBMISSION_ID="$(printf '%s' "${submit_json}" | grep -o '"id" *: *"[^"]*"' | head -1 | sed 's/.*"id" *: *"//;s/"$//' || true)"
if [[ -z "${SUBMISSION_ID}" ]]; then
  echo "ERROR: notarytool returned no submission id:" >&2
  printf '  %s\n' "${submit_json}" >&2
  exit 1
fi
echo "==> Submission ${SUBMISSION_ID} — waiting for Apple (polling every 30s)"
STATUS=""
WAIT_SECONDS=0
while :; do
  STATUS="$(poll_notary_status "${SUBMISSION_ID}")"
  case "${STATUS}" in
    Accepted | Rejected | Invalid) break ;;
    "") printf '  (status poll failed, retrying)\n' >&2 ;;
  esac
  sleep 30
  WAIT_SECONDS=$((WAIT_SECONDS + 30))
  printf '  in progress (%dm%02ds elapsed)\n' $((WAIT_SECONDS / 60)) $((WAIT_SECONDS % 60)) >&2
done
if [[ "${STATUS}" != "Accepted" ]]; then
  echo "ERROR: notarization was not accepted (status: ${STATUS:-unknown})." >&2
  fetch_notary_log "${SUBMISSION_ID}"
  exit 1
fi

# 5. Attach the ticket and verify the whole chain offline.
echo "==> Stapling ${DMG}"
xcrun stapler staple "${DMG}"
echo "==> Validating"
xcrun stapler validate "${DMG}"

echo
echo "Notarized release ready: ${DMG}"
