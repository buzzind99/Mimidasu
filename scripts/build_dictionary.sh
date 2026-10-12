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
# Revision 7 is the first whose artifact carries the case-headword index.
PIN_BUILD="7"

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
# The debug-checkout database: RAW_DB plus the gloss index. RAW_DB already
# carries the case-headword index (jmdict_build.py builds it before
# compression, and it ships inside the bundled artifact); the gloss index is
# the one the app builds at first launch into Application Support and which
# therefore costs the bundle nothing. Tests and debug runs resolve this file
# (see JMDictPin.devArtifactFileName), so without the gloss index every Latin
# gloss search would run against an index-less database and silently return
# nothing.
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
  local hit=0
  if [[ "${needle}" == "static let schemaVersion = "* ]]; then
    # Anchored to a declaration line and boundary-checked after the pinned
    # value: a bare substring match would let `static let schemaVersion = 10`
    # satisfy the needle for `... = 1`, so a bump would sail past this tripwire
    # without anyone acknowledging it. The bump has to land here — where this
    # message sends the editor — because the stamp below is interpolated from
    # Swift and nothing in the DDL mentions the version.
    if grep -Eq "^[[:space:]]*${needle}([^0-9]|$)" "${FTS_SWIFT}"; then
      hit=1
    fi
  elif grep -Fq -- "${needle}" "${FTS_SWIFT}"; then
    hit=1
  fi
  if (( ! hit )); then
    echo "ERROR: JMDictFTSIndex no longer contains: ${needle}" >&2
    if [[ "${needle}" == "static let schemaVersion = "* ]]; then
      echo "  update this grep literal (the stamp itself is interpolated from Swift)." >&2
    else
      echo "  update the dev-artifact DDL in ${BASH_SOURCE[0]} to match." >&2
    fi
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
FTS_SCHEMA_VERSION="$(sed -n 's/^[[:space:]]*static let schemaVersion = \([0-9][0-9]*\).*/\1/p' "${FTS_SWIFT}" | head -1)"
if [[ -z "${FTS_SCHEMA_VERSION}" ]]; then
  echo "ERROR: could not read JMDictFTSIndex.schemaVersion out of ${FTS_SWIFT}." >&2
  exit 1
fi
echo "    fts.schemaVersion: ${FTS_SCHEMA_VERSION}"
# The table name and the rowid stride are read rather than repeated, so the
# skip guard above, the DDL heredoc below, and the `MAX(ord)` guard all speak
# about the same values Swift does. The patterns anchor to a declaration line
# (`^[[:space:]]*`), so a doc comment quoting the constant can never be the
# line the parse picks up.
FTS_TABLE_NAME="$(sed -n 's/^[[:space:]]*static let tableName = "\([^"]*\)".*/\1/p' "${FTS_SWIFT}" | head -1)"
FTS_ORD_STRIDE="$(sed -n 's/^[[:space:]]*static let ordStride = \([0-9][0-9]*\).*/\1/p' "${FTS_SWIFT}" | head -1)"
FTS_ORD_SHIFT="$(sed -n 's/^[[:space:]]*static let ordShift = \([0-9][0-9]*\).*/\1/p' "${FTS_SWIFT}" | head -1)"
if [[ -z "${FTS_TABLE_NAME}" || -z "${FTS_ORD_STRIDE}" || -z "${FTS_ORD_SHIFT}" ]]; then
  echo "ERROR: could not read JMDictFTSIndex.tableName/ordStride/ordShift out of ${FTS_SWIFT}." >&2
  exit 1
fi
# Swift only `assert`s the stride/shift relation (stripped from release
# builds), so bumping one while missing the other would ship a dev database
# that release builds decode wrongly.
if (( FTS_ORD_STRIDE != (1 << FTS_ORD_SHIFT) )); then
  echo "ERROR: JMDictFTSIndex ordStride ${FTS_ORD_STRIDE} != 1 << ordShift ${FTS_ORD_SHIFT}." >&2
  exit 1
fi
echo "    fts.${FTS_TABLE_NAME} rowid stride: ${FTS_ORD_STRIDE}"

# The case-headword index is a second copy of a schema kept in Swift
# (JMDictCaseIndex), guarded the same way — with the difference that the
# shipped artifact now carries it, built by jmdict_build.py from a third
# copy of the DDL pinned below. The app never writes the index, so these
# guards are what keep a dropped or drifted build from shipping: the load
# would silently fall back to a full scan of headwords. The engine's answers
# are the same either way.
CASE_SWIFT="${REPO_ROOT}/Mimidasu/Dictionary/JMDictCaseIndex.swift"
if [[ ! -f "${CASE_SWIFT}" ]]; then
  echo "ERROR: ${CASE_SWIFT} not found; the case index DDL must exist in Swift and here." >&2
  exit 1
fi
check_case_constant() {
  local needle="$1"
  if ! grep -Fq -- "${needle}" "${CASE_SWIFT}"; then
    echo "ERROR: JMDictCaseIndex no longer contains: ${needle}" >&2
    echo "  update the ingestion DDL in ${BASH_SOURCE[0]} and jmdict_build.py to match." >&2
    exit 1
  fi
  echo "    case.${needle}: ok"
}
check_case_constant 'static let indexName = "headwords_case"'
check_case_constant "WHERE text <> lower(text)"
# The load rides the index only if its predicate is textually the index's own,
# so the two statements are compared rather than merely both guarded.
CASE_PREDICATE="$(sed -n 's/^[[:space:]]*static let loadSQL = "\(.*\)"$/\1/p' "${CASE_SWIFT}" | head -1)"
if [[ -z "${CASE_PREDICATE}" ]]; then
  # A failed parse and a dropped predicate are different problems — the first
  # means `loadSQL` stopped matching this one-line declaration (reformatted to
  # a `"""` literal, say), not that its WHERE clause changed.
  echo "ERROR: could not read JMDictCaseIndex.loadSQL out of ${CASE_SWIFT};" >&2
  echo "  expected a single-line static let loadSQL = \"…\" declaration." >&2
  exit 1
fi
if [[ "${CASE_PREDICATE}" != *"WHERE text <> lower(text)"* ]]; then
  echo "ERROR: JMDictCaseIndex.loadSQL no longer carries the index's predicate;" >&2
  echo "  the load would silently fall back to a full scan of headwords." >&2
  exit 1
fi
echo "    case.loadSQL predicate: ok"
# The second load is a primary-key range scan over the blocks that carry case,
# and the engine is only complete if it is still there: the ASCII predicate
# skips the 26 Greek-capital name rows on the pinned corpus.
check_case_constant 'static let nonASCIICaseFloor = "'
check_case_constant 'static let nonASCIICaseCeiling = "'
check_case_constant 'WHERE text >='
# The needles above pin the declarations; the probes further down must query
# the bounds Swift actually loads, so the codepoints are read out of the Swift
# source the same way FTS_SCHEMA_VERSION is, and probed as SQLite char(0x…) —
# no literals here to drift.
CASE_FLOOR="$(sed -n 's/.*nonASCIICaseFloor = "\\u{\([0-9A-Fa-f]*\)}".*/\1/p' "${CASE_SWIFT}" | head -1)"
CASE_CEILING="$(sed -n 's/.*nonASCIICaseCeiling = "\\u{\([0-9A-Fa-f]*\)}".*/\1/p' "${CASE_SWIFT}" | head -1)"
if [[ ! "${CASE_FLOOR}" =~ ^[0-9A-Fa-f]{1,6}$ || ! "${CASE_CEILING}" =~ ^[0-9A-Fa-f]{1,6}$ ]]; then
  echo "ERROR: could not read the non-ASCII case bounds out of ${CASE_SWIFT}." >&2
  exit 1
fi
echo "    case.range: char(0x${CASE_FLOOR}) ..< char(0x${CASE_CEILING})"
# The build's copy of the DDL, pinned the way GLOSS_JOINER is: both fragments
# must exist in jmdict_build.py or the shipped artifact would quietly lose
# the index every future rebuild.
CASE_PY="${REPO_ROOT}/scripts/jmdict_build.py"
if ! grep -Fq 'CREATE INDEX IF NOT EXISTS headwords_case ON headwords(text)' "${CASE_PY}" \
  || ! grep -Fq '" WHERE text <> lower(text)"' "${CASE_PY}"; then
  echo "ERROR: jmdict_build.py no longer builds the case-headword index;" >&2
  echo "  the shipped artifact must carry it (see HEADWORDS_CASE_DDL there)." >&2
  exit 1
fi
echo "    case.jmdict_build.py DDL: ok"

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

# The dev artifact is adoptable only if it carries the gloss index at the
# current stamp — the same condition `JMDictFTSIndex.isPresent` applies on the
# app side, and for the same reason: an index-less database is complete and
# SQLite-valid yet answers every Latin gloss query with zero rows and no error,
# because the `LIKE` fallback is gone. `-s` cannot see that difference; an
# interrupted index build (Ctrl-C, or an sqlite3 without the trigram tokenizer)
# leaves exactly that file behind. The table presence is checked as well as the
# stamp, so a database that was stamped but whose `gloss_fts` never landed is
# still rebuilt.
dev_db_is_adoptable() {
  [[ -s "${DEV_DB}" ]] || return 1
  local stamp table
  stamp="$(sqlite3 "${DEV_DB}" 'PRAGMA user_version;' 2>/dev/null || true)"
  [[ "${stamp}" == "${FTS_SCHEMA_VERSION}" ]] || return 1
  table="$(sqlite3 "${DEV_DB}" \
    "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '${FTS_TABLE_NAME}';" \
    2>/dev/null || true)"
  [[ "${table}" == "1" ]]
}

# Up-to-date skip (build mode only): the artifact name is versioned by the
# pin tag + build revision, so a pin bump or a revision bump naturally misses
# and rebuilds. A truncated artifact from an interrupted build fails
# `zstd -t` and falls through to a rebuild. --rebuild bypasses this entirely
# (needed when the build mapping changes under the same pin). --probe-only
# never consults the DB.
if [[ "${MODE}" == "build" && "${REBUILD}" == "0" && -s "${ZST_PATH}" ]]; then
  if ! command -v zstd >/dev/null 2>&1; then
    echo "WARNING: zstd not found; cannot verify ${ZST_NAME}, rebuilding."
  else
    # Tested once and kept: the two arms below ask the same question, so the
    # old chain read the whole artifact twice to learn the same answer.
    ZST_INTACT=1
    zstd -q -t "${ZST_PATH}" 2>/dev/null || ZST_INTACT=0
    if (( ZST_INTACT )) && dev_db_is_adoptable; then
      echo "==> ${ZST_NAME} already built and valid; skipping (use --rebuild to force)."
      exit 0
    elif (( ZST_INTACT )); then
      # The bundle is fine but the dev artifact is missing, empty, unstamped or
      # index-less — a pin bump that skipped, or an interrupted index build.
      # Rebuild both rather than leaving a checkout whose live tests resolve a
      # database that answers every gloss query with nothing.
      echo "==> ${ZST_NAME} is valid but $(basename "${DEV_DB}") is missing or carries no current gloss index; rebuilding."
    else
      echo "WARNING: ${ZST_PATH} exists but failed its integrity check; rebuilding."
    fi
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
# applies at first launch. The case-headword index needs nothing here — RAW_DB
# carries it because jmdict_build.py built it before compression, and the
# probes below refuse to publish if that ever stops being true. Debug
# checkouts and the live tests resolve this file rather than RAW_DB, because
# the app has no LIKE fallback and a database with no gloss index answers
# every Latin gloss query with zero rows.
echo "==> Building $(basename "${DEV_DB}") (gloss index; case index inherited)"
# A pin bump renames the artifact; sweep the dev artifact's predecessors the
# same way the app sweeps stale prepared databases, so build/ cannot accumulate
# a 140 MB file per past pin. The sweep runs BEFORE the build and must stay
# there: its glob matches every jmdict-*.dev.sqlite, the artifact this step is
# about to produce included — swept after the build, it deletes the file the
# live tests resolve and silently disables them.
rm -f "${BUILD_DIR}"/jmdict-*.dev.sqlite
rm -f "${DEV_DB}"
cp "${RAW_DB}" "${DEV_DB}"
# The rowid pack is load-bearing: every gloss row is read back by primary key,
# so two senses colliding onto one rowid hands the stage another entry's gloss,
# wrong answers with no error anywhere. Swift's `guardMaxOrd` refuses the same
# corpus at first launch; the dev artifact is what the live tests resolve, so it
# gets the same refusal here — before the index is written, not after.
MAX_ORD="$(sqlite3 "${DEV_DB}" 'SELECT MAX(ord) FROM senses;')"
if [[ -n "${MAX_ORD}" ]] && (( MAX_ORD >= FTS_ORD_STRIDE )); then
  rm -f "${DEV_DB}"
  echo "ERROR: a sense carries ord ${MAX_ORD}, past the ${FTS_ORD_STRIDE}-wide rowid pack (dev db removed);" >&2
  echo "  refusing to publish $(basename "${DEV_DB}")" >&2
  exit 1
fi
echo "    max(ord) ${MAX_ORD:-0} fits the ${FTS_ORD_STRIDE}-wide rowid pack"
# `-bail` is load-bearing, not tidiness. Without it sqlite3 logs the failed
# statement and carries on, so a `CREATE VIRTUAL TABLE` that cannot be created
# (an sqlite3 built without the trigram tokenizer) still reaches the trailing
# `PRAGMA user_version` — leaving a complete, SQLite-valid, *index-less*
# database stamped as current, which every later skip would bless.
sqlite3 -bail "${DEV_DB}" <<FTSEOF
CREATE VIRTUAL TABLE ${FTS_TABLE_NAME} USING fts5(
  gloss,
  tokenize='trigram case_sensitive 0 remove_diacritics 0',
  content='', columnsize=0);
INSERT INTO ${FTS_TABLE_NAME}(rowid, gloss)
  SELECT entry_id * ${FTS_ORD_STRIDE} + ord, gloss FROM senses;
INSERT INTO ${FTS_TABLE_NAME}(${FTS_TABLE_NAME}) VALUES('optimize');
PRAGMA user_version = ${FTS_SCHEMA_VERSION};
FTSEOF
# The case index ships in the artifact, so its absence here means the
# ingestion build dropped it — refuse before any plan probe pretends
# otherwise.
CASE_PRESENT="$(sqlite3 "${DEV_DB}" "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'headwords_case';")"
if [[ -z "${CASE_PRESENT}" ]]; then
  rm -f "${DEV_DB}"
  echo "ERROR: the built database does not carry the case-headword index (dev db removed);" >&2
  echo "  jmdict_build.py must execute HEADWORDS_CASE_DDL before compressing." >&2
  exit 1
fi
# The case index is an optimization, so the probe checks the property it exists
# for: the load must be answered by the index rather than by the full walk. A
# predicate that drifted from the index's would still return the same rows, and
# only the plan would show it.
CASE_PLAN="$(sqlite3 "${DEV_DB}" "EXPLAIN QUERY PLAN SELECT DISTINCT text FROM headwords WHERE text <> lower(text);" 2>&1)"
if [[ "${CASE_PLAN}" != *"USING COVERING INDEX headwords_case"* ]]; then
  rm -f "${DEV_DB}"
  echo "ERROR: the case load is not served by headwords_case (dev db removed); got: ${CASE_PLAN}" >&2
  echo "  refusing to publish $(basename "${DEV_DB}")" >&2
  exit 1
fi
CASE_ROWS="$(sqlite3 "${DEV_DB}" "SELECT count(DISTINCT text) FROM headwords WHERE text <> lower(text);")"
if [[ -z "${CASE_ROWS}" || "${CASE_ROWS}" == "0" ]]; then
  rm -f "${DEV_DB}"
  echo "ERROR: case-headword index built but the load answers nothing (dev db removed);" >&2
  echo "  refusing to publish $(basename "${DEV_DB}")" >&2
  exit 1
fi
# The range load must also answer, and it must be a range scan rather than a
# walk: a drifted bound would quietly turn it into the full scan the ASCII
# index exists to avoid. The bounds are Swift's own (read above), so the probe
# queries what the app loads rather than a literal copied here.
CASE_RANGE_PREDICATE="text >= char(0x${CASE_FLOOR}) AND text < char(0x${CASE_CEILING})"
CASE_RANGE_PLAN="$(sqlite3 "${DEV_DB}" "EXPLAIN QUERY PLAN SELECT DISTINCT text FROM headwords WHERE ${CASE_RANGE_PREDICATE};" 2>&1)"
CASE_RANGE_ROWS="$(sqlite3 "${DEV_DB}" "SELECT count(DISTINCT text) FROM headwords WHERE ${CASE_RANGE_PREDICATE};")"
if [[ -z "${CASE_RANGE_ROWS}" || "${CASE_RANGE_ROWS}" == "0" \
   || "${CASE_RANGE_PLAN}" != *"SEARCH headwords USING PRIMARY KEY"* ]]; then
  rm -f "${DEV_DB}"
  echo "ERROR: the non-ASCII case load is empty or not a range scan (dev db removed): ${CASE_RANGE_PLAN}" >&2
  echo "  refusing to publish $(basename "${DEV_DB}")" >&2
  exit 1
fi
echo "    headwords_case answers ${CASE_ROWS} spellings, the range load ${CASE_RANGE_ROWS}"
# Present-but-empty is the failure worth catching: it passes every schema probe
# and then answers nothing, which is indistinguishable from "no such gloss".
# A count(*) cannot detect it — a contentless FTS5 table refuses to be scanned
# — so the probe is a trigram of a gloss that is known to exist.
#
# The trigram is chosen from glosses whose first three characters contain
# neither quote, so it can be spliced into the MATCH literal below without
# escaping. Escaping it *in SQL* is not an option: FTS5 requires the MATCH
# argument to be a constant, so a phrase computed from the row (however it is
# quoted) makes SQLite stop treating MATCH as a constraint and try to scan the
# contentless table instead — the probe dies with "table does not support
# scanning". Filtering the probe source by quoting is the one shape that keeps
# the argument a literal: 329 of the pinned corpus's 656,706 gloss columns
# carry a quote in the three characters the probe splices, so the quote filter
# drops only those — 656,377 still qualify — and this costs the probe no reach.
# The second guard keeps the pick *usable* rather
# than merely quote-free: FTS5 answers a shorter-than-three-character phrase
# with zero rows and no error, so the trigram has to be exactly three scalars.
#
# The whitespace exclusions are belt-and-braces, and only one is load-bearing.
# The trigram tokenizer indexes every three-scalar window, whitespace included
# (probed on the pinned SQLite: 'ab cd' yields 'ab ', 'b c' and ' cd', and the
# phrases "ab ", "ab<TAB>", "ab<LF>", "ab<CR>", "ab<VT>" and "ab<FF>" each
# match their own row), so no separator has to be avoided in the phrase itself.
# What does bite is command substitution in the assignment below: it strips
# trailing newlines, so a trigram ending in one would collapse below three
# scalars by the time it reached MATCH. char(10) earns its place for that
# reason alone; the space and char(13) filters are kept because each costs one
# instr() call per row in a scan that already happens, and because a comment
# reading as "the tokenizer separates here" would be the false lead the next
# editor acts on. This WHERE clause is kept byte-identical to the one in
# scripts/lib/ensure_test_dictionaries.sh.
PROBE="$(sqlite3 "${DEV_DB}" "SELECT substr(gloss, 1, 3) FROM senses
  WHERE gloss <> '' AND substr(gloss, 1, 3) NOT GLOB '*[\"'']*'
    AND length(substr(gloss, 1, 3)) = 3
    AND instr(substr(gloss, 1, 3), ' ') = 0
    AND instr(substr(gloss, 1, 3), char(10)) = 0
    AND instr(substr(gloss, 1, 3), char(13)) = 0
  LIMIT 1;")"
INDEX_ROWS="$(sqlite3 "${DEV_DB}" "SELECT count(*) FROM ${FTS_TABLE_NAME} WHERE ${FTS_TABLE_NAME} MATCH '\"${PROBE}\"';")"
if [[ -z "${PROBE}" || "${INDEX_ROWS}" == "0" || -z "${INDEX_ROWS}" ]]; then
  rm -f "${DEV_DB}"
  echo "ERROR: gloss index built but answers nothing for its own probe '${PROBE}' (dev db removed);" >&2
  echo "  refusing to publish $(basename "${DEV_DB}")" >&2
  exit 1
fi
echo "    ${FTS_TABLE_NAME} answers '${PROBE}' on ${INDEX_ROWS} senses"

# Sweep the artifacts earlier pins left behind. Deliberately last: RAW_DB is
# what the dev artifact was just built from, and a run interrupted before this
# point must still leave the checkout with a usable pair. `jmdict-*.sqlite`
# matches the dev artifact too (its name only adds `.dev`), so it is excluded
# by name rather than by pattern.
for stale in "${BUILD_DIR}"/jmdict-*.sqlite; do
  if [[ -e "${stale}" && "${stale}" != "${RAW_DB}" && "${stale}" != "${DEV_DB}" ]]; then
    echo "    sweeping stale $(basename "${stale}")"
    rm -f "${stale}"
  fi
done
for stale in "${DICT_DIR}"/jmdict-*.sqlite.zst; do
  if [[ -e "${stale}" && "${stale}" != "${ZST_PATH}" ]]; then
    echo "    sweeping stale $(basename "${stale}")"
    rm -f "${stale}"
  fi
done

echo
echo "Done. package.sh bundles ${ZST_NAME} into Mimidasu.app/Contents/Resources;"
echo "DictionaryStore stages/decompresses it to ${PREPARED_NAME} and builds the"
echo "gloss index (the case-headword index ships inside the artifact)."
echo "Debug checkouts resolve $(basename "${DEV_DB}")."
