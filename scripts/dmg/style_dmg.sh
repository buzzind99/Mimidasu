#!/usr/bin/env bash
#
# Styled DMGs in one place. This file does double duty:
#
#   - sourced: provides style_dmg() to scripts/package.sh (release DMG), so
#     the Finder background and icon layout bake in before scripts/notarize.sh
#     submits — styling must never happen after notarization.
#   - executed: builds a `-styled` preview from the staged app and opens it:
#       scripts/dmg/style_dmg.sh [volume_name]
#
# Built on dmgbuild (pip install dmgbuild — needs Python 3.10+), which writes
# the .DS_Store directly instead of driving Finder via AppleScript. No GUI
# session needed. Hard requirement by design: fail fast rather than silently
# ship an unstyled DMG.
#
# Layout lives in scripts/dmg/dmg_settings.py; art in background.png.
#
# Sourcing scripts must set REPO_ROOT (absolute repo root) first.

style_dmg() {
  local app="$1" volname="$2" out="$3"
  local open_after=0
  if [[ "${4:-}" == "--open" ]]; then
    open_after=1
  fi

  command -v dmgbuild >/dev/null || {
    echo "ERROR: dmgbuild required (pip install dmgbuild — needs Python 3.10+)" >&2
    return 1
  }
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' || {
    echo "ERROR: dmgbuild needs Python 3.10+ (found: $(python3 --version 2>&1))" >&2
    return 1
  }

  local settings="${REPO_ROOT}/scripts/dmg/dmg_settings.py"
  local bg="${REPO_ROOT}/scripts/dmg/background.png"
  [[ -f "${settings}" ]] || {
    echo "ERROR: DMG settings missing: ${settings}" >&2
    return 1
  }
  [[ -f "${bg}" ]] || {
    echo "ERROR: DMG background missing: ${bg}" >&2
    return 1
  }
  [[ -d "${app}" ]] || {
    echo "ERROR: app missing: ${app} (run scripts/package.sh first)" >&2
    return 1
  }

  rm -f "${out}"
  dmgbuild -s "${settings}" -D "app=${app}" -D "bg=${bg}" "${volname}" "${out}"

  if (( open_after )); then
    local mount="/Volumes/${volname}"
    if [[ -d "${mount}" ]]; then
      hdiutil detach "${mount}" >/dev/null 2>&1 || true
    fi
    hdiutil attach "${out}" -nobrowse -readonly >/dev/null
    open "${mount}"
  fi
  echo "Styled DMG ready: ${out}"
}

# Preview when executed directly (no-op when sourced).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail

  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  APP_VERSION="${APP_VERSION:-$(sed -n 's/^ *MARKETING_VERSION: *"\([^"]*\)".*/\1/p' "${REPO_ROOT}/project.yml" | head -1 || true)}"
  if [[ -z "${APP_VERSION}" ]]; then
    echo "ERROR: could not read MARKETING_VERSION from project.yml (or override with APP_VERSION)" >&2
    exit 1
  fi
  VOL_NAME="${1:-Mimidasu-${APP_VERSION}}"
  APP="${REPO_ROOT}/build/pkg/Mimidasu.app"
  OUT="${REPO_ROOT}/build/pkg/${VOL_NAME}-styled.dmg"

  cd "${REPO_ROOT}"

  [[ -d "${APP}" ]] || {
    echo "ERROR: ${APP} missing (run scripts/package.sh first)" >&2
    exit 1
  }

  style_dmg "${APP}" "${VOL_NAME}" "${OUT}" --open
fi
