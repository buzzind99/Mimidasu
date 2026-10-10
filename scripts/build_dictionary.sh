#!/usr/bin/env bash
#
# Fetch + verify the pinned JMDict_Extended and JMnedict release assets, probe
# their formats, and emit the bundled lookup DB from them. The probe and build
# implementations live in jmdict_probe.py and jmdict_build.py (same directory);
# this script is the orchestrator and the only supported entrypoint.
#
#   scripts/build_dictionary.sh            # probe (tripwire) + build DB (skips if built)
#   scripts/build_dictionary.sh --probe-only   # probe only, no DB emitted
#   scripts/build_dictionary.sh --rebuild      # probe + rebuild DB even if built
#
# The pin (tag + asset + SHA-256 + local build revision) is recorded here AND
# in Mimidasu/Dictionary/JMDictPin.swift; this script cross-checks the two and
# hard-fails on drift, so a pin bump must touch both files or nothing builds.
# The probe runs before every build and hard-fails on any mismatch with the
# documented input contract — on a pin bump it is the tripwire against silent
# upstream format drift, and the DB is only ever built from a probed-pass
# asset. (The only exception is the up-to-date skip: when the versioned
# artifact for this pin already exists and passes `zstd -t`, plain
# invocations exit early without re-downloading, re-probing, or rebuilding;
# --rebuild forces the full path.)
#
# Artifacts (gitignored, under local/ and build/):
#   local/dictionaries/jmdictExtended-<date>.json.zip   pinned JMDict release asset
#   local/dictionaries/jmdictExtended-<date>.json       unzipped JMDict input
#   local/dictionaries/jmnedict-all-<version+ts>.json.zip  pinned JMnedict (names) asset
#   local/dictionaries/jmnedict-all-<version>.json      unzipped names input
#   local/dictionaries/jmdict-<tag>.<rev>.sqlite.zst    bundled lookup DB
#                                                       (package.sh -> Contents/Resources)
#   build/jmdict-<tag>.<rev>.sqlite                     uncompressed intermediate
#   build/jmdict-probe.log                              full probe report
#   build/jmdict-build.log                              full build log
#
# The bundled artifact name is keyed on the JMDict tag + local build revision
# (the names release rides inside the artifact), so a names-only pin bump
# skips as up-to-date and needs `--rebuild` to take effect — while a
# build-revision bump renames the artifact and naturally rebuilds.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DICT_DIR="${REPO_ROOT}/local/dictionaries"
BUILD_DIR="${REPO_ROOT}/build"

# --- Pin: keep in sync with Mimidasu/Dictionary/JMDictPin.swift -----------------
PIN_TAG="1.4.1-auto-release-2026-09-01"
PIN_ASSET="jmdictExtended-2026-09-01.json.zip"
# SHA-256 of the .zip asset, cross-checked against the digest GitHub publishes
# on the release asset page.
PIN_SHA256="4bee23eb7bd088d0a9c48301d0d25964b8ac9ecd6465c91b40adf8191d4b040a"
PIN_URL="https://github.com/Bluskyo/JMDict_Extended/releases/download/${PIN_TAG}/${PIN_ASSET}"
# Local ingestion-recipe revision, appended to the artifact tag. PIN_TAG must
# stay the upstream release identifier (it keys the download URL); this
# revision is the artifact staleness key — bump it when the build mapping
# changes under the same upstream pin so prepared installs re-stage.
PIN_BUILD="6"

# --- Names pin: JMnedict proper nouns, ingested into the same DB ----------------
# Source is scriptin/jmdict-simplified (the JMDict pin above stays on
# Bluskyo/JMDict_Extended); the two bump independently.
NAME_PIN_TAG="3.6.2+20260914172325"
NAME_PIN_ASSET="jmnedict-all-3.6.2+20260914172325.json.zip"
NAME_PIN_SHA256="843470cd19284d6caea54e6027df1791402766bd90ba70d36dba0cd787aeaa2a"
NAME_PIN_URL="https://github.com/scriptin/jmdict-simplified/releases/download/${NAME_PIN_TAG}/${NAME_PIN_ASSET}"
# -------------------------------------------------------------------------------

ZIP_PATH="${DICT_DIR}/${PIN_ASSET}"
JSON_PATH="${DICT_DIR}/${PIN_ASSET%.zip}"
# The names zip's inner file drops the +build-timestamp suffix.
NAME_ZIP_PATH="${DICT_DIR}/${NAME_PIN_ASSET}"
NAME_JSON_PATH="${DICT_DIR}/jmnedict-all-${NAME_PIN_TAG%%+*}.json"
PROBE_LOG="${BUILD_DIR}/jmdict-probe.log"
# The artifact tag adds the local build revision to the upstream release tag;
# the versioned filename built from it is the staleness key everywhere.
ARTIFACT_TAG="${PIN_TAG}.${PIN_BUILD}"
PREPARED_NAME="jmdict-${ARTIFACT_TAG}.sqlite"
ZST_NAME="${PREPARED_NAME}.zst"
ZST_PATH="${DICT_DIR}/${ZST_NAME}"
# The debug-checkout database. Same rows as RAW_DB plus the gloss index, which
# the app builds at first launch into Application Support and which therefore
# costs the bundle nothing. Tests and debug runs resolve this file (see
# JMDictPin.devArtifactFileName), so without it every Latin gloss search would
# run against an index-less database and silently return nothing.
DEV_DB="${BUILD_DIR}/jmdict-${ARTIFACT_TAG}.dev.sqlite"

MODE="build"
REBUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --probe-only) MODE="probe" ;;
    --rebuild) REBUILD=1 ;;
    -h|--help)
      echo "usage: build_dictionary.sh [--probe-only] [--rebuild]"
      echo "  (default)    probe the pinned asset, then build the DB (skips if built)"
      echo "  --probe-only probe only, no DB emitted"
      echo "  --rebuild    probe + rebuild the DB even if the artifact exists"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1 (see --help)" >&2
      exit 1
      ;;
  esac
  shift
done
if [[ "${MODE}" == "probe" && "${REBUILD}" == "1" ]]; then
  echo "ERROR: --probe-only and --rebuild are mutually exclusive" >&2
  exit 1
fi

echo "==> JMDict_Extended pin: ${PIN_TAG}"
echo "    asset: ${PIN_ASSET}"
echo "==> JMnedict names pin: ${NAME_PIN_TAG}"
echo "    asset: ${NAME_PIN_ASSET}"

# Cross-check the Swift pin constants (drift fails here, never silently).
PIN_SWIFT="${REPO_ROOT}/Mimidasu/Dictionary/JMDictPin.swift"
if [[ ! -f "${PIN_SWIFT}" ]]; then
  echo "ERROR: ${PIN_SWIFT} not found; the pin must exist in both the script and Swift." >&2
  exit 1
fi
check_pin_constant() {
  local name="$1" expected="$2"
  python3 - "$name" "$expected" "${PIN_SWIFT}" <<'CHECKEOF'
import re, sys
name, expected, path = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path, encoding="utf-8").read()
m = re.search(rf'\b{name}\s*=\s*"([^"]+)"', src)
actual = m.group(1) if m else None
if actual != expected:
    print(f"ERROR: JMDictPin.{name} mismatch\n  script: {expected}\n  swift:  {actual}", file=sys.stderr)
    sys.exit(1)
CHECKEOF
  echo "    pin.${name}: ok"
}
check_pin_constant releaseTag "${PIN_TAG}"
check_pin_constant sourceAssetFileName "${PIN_ASSET}"
check_pin_constant sourceSHA256 "${PIN_SHA256}"
check_pin_constant buildRevision "${PIN_BUILD}"
check_pin_constant nameReleaseTag "${NAME_PIN_TAG}"
check_pin_constant nameSourceAssetFileName "${NAME_PIN_ASSET}"
check_pin_constant nameSourceSHA256 "${NAME_PIN_SHA256}"

# The gloss joiner is a cross-language ingestion constant: jmdict_build.py
# joins a sense's glosses with it and JMDictPin.glossJoiner is the character
# every Swift consumer splits the column back on. A drift between the two
# would fuse every multi-gloss sense into one unsplit string on the Swift
# side, so both declarations are pinned literally here, and the live corpus
# tests (which read the Python-built database while the fixture exercises the
# Swift constant) are the runtime backstop.
if ! grep -Fq 'GLOSS_JOINER = "\x1f"' "${REPO_ROOT}/scripts/jmdict_build.py"; then
  echo "ERROR: jmdict_build.py no longer declares GLOSS_JOINER = \"\x1f\"; update this drift guard." >&2
  exit 1
fi
echo "    gloss.GLOSS_JOINER: ok"
if ! grep -Fq 'static let glossJoiner: Unicode.Scalar = "\u{001F}"' "${PIN_SWIFT}"; then
  echo "ERROR: JMDictPin.glossJoiner no longer matches; update this drift guard." >&2
  exit 1
fi
echo "    gloss.glossJoiner: ok"

# The gloss FTS index's DDL lives in Swift (JMDictFTSIndex) and is re-stated
# below to build the dev artifact. Two copies of a schema is exactly the kind
# of duplication that rots, so the parts that must agree are grepped here and
# the build hard-fails on drift — same idiom as the pin constants above. The
# tokenizer options are the load-bearing ones: the whole recall argument for
# this index rests on `case_sensitive 0` folding the case that `LIKE` could
# not, and on `remove_diacritics 0` keeping the fold from reaching further.
FTS_SWIFT="${REPO_ROOT}/Mimidasu/Dictionary/JMDictFTSIndex.swift"
if [[ ! -f "${FTS_SWIFT}" ]]; then
  echo "ERROR: ${FTS_SWIFT} not found; the gloss index DDL must exist in Swift and here." >&2
  exit 1
fi
check_fts_constant() {
  local needle="$1"
  if ! grep -Fq -- "${needle}" "${FTS_SWIFT}"; then
    echo "ERROR: JMDictFTSIndex no longer contains: ${needle}" >&2
    echo "  update the dev-artifact DDL in ${BASH_SOURCE[0]} to match." >&2
    exit 1
  fi
  echo "    fts.${needle}: ok"
}
check_fts_constant 'static let tableName = "gloss_fts"'
check_fts_constant 'static let ordStride = 128'
check_fts_constant 'static let ordShift = 7'
check_fts_constant "case_sensitive 0 remove_diacritics 0"
check_fts_constant 'static let schemaVersion = 1'
# The stamp is what makes the dev artifact adoptable rather than permanently
# stale, so it is interpolated from the same constant the guard above pins.
FTS_SCHEMA_VERSION="$(sed -n 's/.*static let schemaVersion = \([0-9][0-9]*\).*/\1/p' "${FTS_SWIFT}" | head -1)"
if [[ -z "${FTS_SCHEMA_VERSION}" ]]; then
  echo "ERROR: could not read JMDictFTSIndex.schemaVersion out of ${FTS_SWIFT}." >&2
  exit 1
fi
echo "    fts.schemaVersion: ${FTS_SCHEMA_VERSION}"

# The produced artifact filename must match the Swift pin constants — the
# versioned name is the staleness key (§0.1 item 4). preparedFileName is
# interpolated in Swift, so guard the derivation expressions themselves
# (releaseTag is already cross-checked above, which pins the concrete name).
if ! grep -Fq 'static let preparedFileName = "\(artifactPrefix)\(releaseTag).\(buildRevision).\(artifactExtension)"' "${PIN_SWIFT}"; then
  echo "ERROR: JMDictPin.preparedFileName no longer derives from artifactPrefix + releaseTag + buildRevision + artifactExtension; update this drift guard." >&2
  exit 1
fi
if ! grep -Fq 'static let artifactPrefix = "jmdict-"' "${PIN_SWIFT}"; then
  echo "ERROR: JMDictPin.artifactPrefix is no longer \"jmdict-\"; update this drift guard." >&2
  exit 1
fi
if ! grep -Fq 'static let artifactExtension = "sqlite"' "${PIN_SWIFT}"; then
  echo "ERROR: JMDictPin.artifactExtension is no longer \"sqlite\"; update this drift guard." >&2
  exit 1
fi
if ! grep -Fq 'bundledFileName = preparedFileName + ".zst"' "${PIN_SWIFT}"; then
  echo "ERROR: JMDictPin.bundledFileName no longer derives from preparedFileName + \".zst\"; update this drift guard." >&2
  exit 1
fi

# Up-to-date skip (build mode only): the artifact name is versioned by the
# pin tag + build revision, so a pin bump or a revision bump naturally misses
# and rebuilds. A truncated artifact from an interrupted build fails
# `zstd -t` and falls through to a rebuild. --rebuild bypasses this entirely
# (needed when the build mapping changes under the same pin). --probe-only
# never consults the DB.
if [[ "${MODE}" == "build" && "${REBUILD}" == "0" && -s "${ZST_PATH}" ]]; then
  if ! command -v zstd >/dev/null 2>&1; then
    echo "WARNING: zstd not found; cannot verify ${ZST_NAME}, rebuilding."
  elif zstd -q -t "${ZST_PATH}" 2>/dev/null && [[ -s "${DEV_DB}" ]]; then
    echo "==> ${ZST_NAME} already built and valid; skipping (use --rebuild to force)."
    exit 0
  elif zstd -q -t "${ZST_PATH}" 2>/dev/null; then
    # The bundle is fine but the dev artifact is missing or empty — a pin bump
    # that skipped, or an interrupted index build. Rebuild both rather than
    # leaving a checkout whose live tests resolve an index-less database.
    echo "==> ${ZST_NAME} is valid but $(basename "${DEV_DB}") is missing; rebuilding."
  else
    echo "WARNING: ${ZST_PATH} exists but failed its integrity check; rebuilding."
  fi
fi

# Fetch once; verify the digest on every run (like the IPADIC pin).
mkdir -p "${DICT_DIR}" "${BUILD_DIR}"
if [[ ! -f "${ZIP_PATH}" ]]; then
  echo "==> Downloading ${PIN_URL}"
  curl -fL --retry 3 -o "${ZIP_PATH}" "${PIN_URL}"
fi
echo "==> Verifying asset SHA-256"
actual="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
if [[ "${actual}" != "${PIN_SHA256}" ]]; then
  echo "ERROR: asset SHA-256 mismatch" >&2
  echo "  expected ${PIN_SHA256}" >&2
  echo "  got      ${actual}" >&2
  rm -f "${ZIP_PATH}"
  exit 1
fi

if [[ ! -f "${JSON_PATH}" ]]; then
  echo "==> Unzipping to ${JSON_PATH}"
  unzip -o -q "${ZIP_PATH}" -d "${DICT_DIR}"
fi
if [[ ! -f "${JSON_PATH}" ]]; then
  echo "ERROR: expected JMDict member not produced by unzip: ${JSON_PATH}" >&2
  echo "  (the release asset's inner file may have been renamed; check: unzip -l \"${ZIP_PATH}\")" >&2
  exit 1
fi

# Names asset: download once, verify the digest on every run (same pattern).
NAME_ZIP_FRESH=0
if [[ ! -f "${NAME_ZIP_PATH}" ]]; then
  echo "==> Downloading ${NAME_PIN_URL}"
  curl -fL --retry 3 -o "${NAME_ZIP_PATH}" "${NAME_PIN_URL}"
  NAME_ZIP_FRESH=1
fi
echo "==> Verifying names asset SHA-256"
actual="$(shasum -a 256 "${NAME_ZIP_PATH}" | awk '{print $1}')"
if [[ "${actual}" != "${NAME_PIN_SHA256}" ]]; then
  echo "ERROR: names asset SHA-256 mismatch" >&2
  echo "  expected ${NAME_PIN_SHA256}" >&2
  echo "  got      ${actual}" >&2
  rm -f "${NAME_ZIP_PATH}"
  exit 1
fi

# A freshly downloaded zip must (re-)extract: the unzipped name keys on the
# version only, so a same-version re-cut at a new build timestamp would
# otherwise keep feeding the stale JSON to a build that records the new pin.
if [[ "${NAME_ZIP_FRESH}" == "1" || ! -f "${NAME_JSON_PATH}" ]]; then
  echo "==> Unzipping to ${NAME_JSON_PATH}"
  rm -f "${NAME_JSON_PATH}"
  unzip -o -q "${NAME_ZIP_PATH}" -d "${DICT_DIR}"
fi
if [[ ! -f "${NAME_JSON_PATH}" ]]; then
  echo "ERROR: expected names member not produced by unzip: ${NAME_JSON_PATH}" >&2
  echo "  (the release asset's inner file may have been renamed; check: unzip -l \"${NAME_ZIP_PATH}\")" >&2
  exit 1
fi

# Probe on every run that proceeds past the up-to-date skip — build mode
# only continues past a passing probe.
echo "==> Probing format (full report: ${PROBE_LOG})"
python3 "${REPO_ROOT}/scripts/jmdict_probe.py" "${JSON_PATH}" "${NAME_JSON_PATH}" "${PROBE_LOG}"
if [[ "${MODE}" == "probe" ]]; then
  echo
  echo "Probe passed. The pinned asset matches the documented contract."
  exit 0
fi

# ============================================================================
# DB build — the probe above already ran and passed on this exact asset.
#
command -v zstd >/dev/null 2>&1 || {
  echo "ERROR: zstd not found (brew install zstd)" >&2
  exit 1
}

RAW_DB="${BUILD_DIR}/${PREPARED_NAME}"
BUILD_LOG="${BUILD_DIR}/jmdict-build.log"

echo "==> Building ${PREPARED_NAME} (log: ${BUILD_LOG})"
rm -f "${RAW_DB}" "${ZST_PATH}"

python3 "${REPO_ROOT}/scripts/jmdict_build.py" "${JSON_PATH}" "${NAME_JSON_PATH}" "${RAW_DB}" "${ZST_PATH}" \
  "${PROBE_LOG}" "${ARTIFACT_TAG}" "${PIN_SHA256}" "${PIN_ASSET}" \
  "${NAME_PIN_TAG}" "${NAME_PIN_SHA256}" "${NAME_PIN_ASSET}" 2>&1 | tee "${BUILD_LOG}"

zstd -q -t "${ZST_PATH}"

# The dev artifact: RAW_DB plus the gloss index, built by the same DDL the app
# applies at first launch. Debug checkouts and the live tests resolve this file
# rather than RAW_DB, because the app has no LIKE fallback and a database with
# no index answers every Latin gloss query with zero rows.
echo "==> Building $(basename "${DEV_DB}") (gloss index)"
# A pin bump renames the artifact; sweep the dev artifact's predecessors the
# same way the app sweeps stale prepared databases, so build/ cannot accumulate
# a 140 MB file per past pin. The sweep runs BEFORE the build and must stay
# there: its glob matches every jmdict-*.dev.sqlite, the artifact this step is
# about to produce included — swept after the build, it deletes the file the
# live tests resolve and silently disables them.
rm -f "${BUILD_DIR}"/jmdict-*.dev.sqlite
rm -f "${DEV_DB}"
cp "${RAW_DB}" "${DEV_DB}"
sqlite3 "${DEV_DB}" <<FTSEOF
CREATE VIRTUAL TABLE gloss_fts USING fts5(
  gloss,
  tokenize='trigram case_sensitive 0 remove_diacritics 0',
  content='', columnsize=0);
INSERT INTO gloss_fts(rowid, gloss) SELECT entry_id * 128 + ord, gloss FROM senses;
INSERT INTO gloss_fts(gloss_fts) VALUES('optimize');
PRAGMA user_version = ${FTS_SCHEMA_VERSION};
FTSEOF
# Present-but-empty is the failure worth catching: it passes every schema probe
# and then answers nothing, which is indistinguishable from "no such gloss".
# A count(*) cannot detect it — a contentless FTS5 table refuses to be scanned
# — so the probe is a trigram of a gloss that is known to exist.
PROBE="$(sqlite3 "${DEV_DB}" "SELECT substr(gloss, 1, 3) FROM senses WHERE gloss <> '' LIMIT 1;")"
INDEX_ROWS="$(sqlite3 "${DEV_DB}" "SELECT count(*) FROM gloss_fts WHERE gloss_fts MATCH '\"${PROBE}\"';")"
if [[ -z "${PROBE}" || "${INDEX_ROWS}" == "0" ]]; then
  echo "ERROR: gloss index built but answers nothing for its own probe '${PROBE}';" >&2
  echo "  refusing to publish $(basename "${DEV_DB}")" >&2
  exit 1
fi
echo "    gloss_fts answers '${PROBE}' on ${INDEX_ROWS} senses"

echo
echo "Done. package.sh bundles ${ZST_NAME} into Mimidasu.app/Contents/Resources;"
echo "DictionaryStore stages/decompresses it to ${PREPARED_NAME} and builds the index."
echo "Debug checkouts resolve $(basename "${DEV_DB}")."
