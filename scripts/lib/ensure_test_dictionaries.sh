#!/bin/zsh
#   scripts/lib/ensure_test_dictionaries.sh
#
# Makes the dictionary-backed tests self-sufficient in a fresh checkout.
# Everything stays inside the repo — tests never touch
# ~/Library/Application Support (debug builds resolve and prepare inside
# the gitignored build/ tree):
#
#   1. local/ runtime artifacts: builds whatever is missing via
#      build_tokenizer.sh (libdictionary.dylib + tokenizer model) and
#      build_dictionary.sh (pinned JMDict database).
#   2. build/prepared/dictionaries: seeds the prepared artifacts debug
#      builds resolve, decompressing through the same dylib FFI the app
#      uses. Without the seed the first test run would race the test host
#      app's background first-launch prepare.
set -euo pipefail
cd "$(dirname "$0")/../.."

DYLIB="local/frameworks/libdictionary.dylib"
MODEL_ZST="local/dictionaries/ipadic-mecab-2_7_0/system.dic.zst"
PREPARED="build/prepared/dictionaries"
BUILD_DIR="build"
PIN_SWIFT="Mimidasu/Dictionary/JMDictPin.swift"
PIN_TAG=$(python3 -c 'import re, sys; print(re.search(r"releaseTag\s*=\s*\"([^\"]+)\"", open(sys.argv[1]).read()).group(1))' "$PIN_SWIFT")
PIN_BUILD=$(python3 -c 'import re, sys; print(re.search(r"buildRevision\s*=\s*\"([^\"]+)\"", open(sys.argv[1]).read()).group(1))' "$PIN_SWIFT")
# The gloss-index table name is read from Swift for the same reason
# build_dictionary.sh reads it: one source of truth, so a rename in
# JMDictFTSIndex.swift cannot leave this probe querying a table that no
# longer exists. Anchored to a declaration line, so a doc comment quoting the
# constant can never be the match.
FTS_SWIFT="Mimidasu/Dictionary/JMDictFTSIndex.swift"
FTS_TABLE_NAME=$(python3 -c 'import re, sys; print(re.search(r"^[ \t]*static let tableName\s*=\s*\"([^\"]+)\"", open(sys.argv[1]).read(), re.M).group(1))' "$FTS_SWIFT")
# The artifact name keys on tag + build revision (build_dictionary.sh's
# ARTIFACT_TAG); tests resolve the prepared DB by JMDictPin.preparedFileName.
ARTIFACT_TAG="${PIN_TAG}.${PIN_BUILD}"
JMDICT_ZST="local/dictionaries/jmdict-${ARTIFACT_TAG}.sqlite.zst"

if [[ ! -f "$DYLIB" || ! -f "$MODEL_ZST" ]]; then
  echo "  building dictionary runtime + model (scripts/build_tokenizer.sh)"
  scripts/build_tokenizer.sh
fi
if [[ ! -f "$JMDICT_ZST" ]]; then
  echo "  building JMDict database (scripts/build_dictionary.sh)"
  scripts/build_dictionary.sh
fi

# Decompresses a .zst artifact through the staged dictionary runtime — the
# exact call path the app's first-launch prepare uses (dictionary_prepare).
seed() {
  local zst="$1" out="$2"
  if [[ -f "$out" ]]; then return 0; fi
  mkdir -p "$PREPARED"
  echo "  seeding $out"
  swift - "$DYLIB" "$zst" "$out" <<'SEED'
import Foundation

let args = CommandLine.arguments
guard args.count == 4, let lib = dlopen(args[1], RTLD_NOW) else {
    FileHandle.standardError.write("seed: cannot load \(args.count > 1 ? args[1] : "<dylib>")\n".data(using: .utf8)!)
    exit(1)
}
typealias FnPrepare = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
guard let sym = dlsym(lib, "dictionary_prepare") else {
    FileHandle.standardError.write("seed: dictionary_prepare symbol not found\n".data(using: .utf8)!)
    exit(1)
}
let rc = unsafeBitCast(sym, to: FnPrepare.self)(args[2], args[3])
guard rc == 0 else {
    FileHandle.standardError.write("seed: dictionary_prepare failed (rc \(rc))\n".data(using: .utf8)!)
    exit(1)
}
SEED
}

seed "$MODEL_ZST" "$PREPARED/ipadic.dic"
seed "$JMDICT_ZST" "$PREPARED/jmdict-${ARTIFACT_TAG}.sqlite"

# The prepared JMDict database must carry the gloss index, exactly as the app's
# own first-launch prepare leaves it. Seeding by decompressing alone would
# produce an index-less database that resolves ahead of the dev artifact, and
# the gloss stage — which has no LIKE fallback — would answer every Latin query
# with zero rows. So it is copied from the dev artifact instead, which
# build_dictionary.sh has already indexed.
DEV_DB="${BUILD_DIR}/jmdict-${ARTIFACT_TAG}.dev.sqlite"
PREPARED_JM="${PREPARED}/jmdict-${ARTIFACT_TAG}.sqlite"
# `-s`, not `-f`: a 0-byte artifact (an interrupted copy in build_dictionary.sh)
# must not pass the gate, or the probe below fails on it and the copy at the
# end replaces a good prepared database with an empty file.
if [[ -s "${DEV_DB}" ]]; then
  # Probed with a trigram of a gloss that exists rather than a literal word, so
  # the check holds for any corpus the pin might move to. The probe skips glosses
  # whose first three characters contain a quote, so it needs no escaping in the
  # MATCH literal — and it cannot be escaped in SQL instead, because FTS5
  # requires a constant MATCH argument and a computed phrase degrades to a scan
  # of the contentless table. The second guard keeps the pick *usable*: FTS5
  # returns zero rows, no error, for a phrase shorter than three characters, so
  # the trigram has to be exactly three scalars long.
  #
  # The whitespace exclusions are belt-and-braces, and only one is load-bearing.
  # The trigram tokenizer indexes every three-scalar window, whitespace included
  # (probed on the pinned SQLite: 'ab cd' yields 'ab ', 'b c' and ' cd', and the
  # phrases "ab ", "ab<TAB>", "ab<LF>", "ab<CR>", "ab<VT>" and "ab<FF>" each
  # match their own row), so no separator has to be avoided there. What does
  # bite is command substitution in the assignment below: it strips trailing
  # newlines, so a trigram ending in one would collapse below three scalars by
  # the time it reaches MATCH. char(10) earns its place for that reason alone;
  # the space and char(13) filters are kept because each costs one instr()
  # call per row in a scan that already happens, and the comment they sit
  # under must not read as a claim the tokenizer does not honour.
  #
  # Both probes must tolerate failure: on a freshly
  # seeded database the gloss index does not exist yet, sqlite3 exits non-zero,
  # and under `set -e` an unchecked substitution would kill this script before
  # the copy below ever runs.
  #
  # This WHERE clause is kept byte-identical to the one in
  # scripts/build_dictionary.sh.
  PROBE="$(sqlite3 "${PREPARED_JM}" "SELECT substr(gloss, 1, 3) FROM senses
  WHERE gloss <> '' AND substr(gloss, 1, 3) NOT GLOB '*[\"'']*'
    AND length(substr(gloss, 1, 3)) = 3
    AND instr(substr(gloss, 1, 3), ' ') = 0
    AND instr(substr(gloss, 1, 3), char(10)) = 0
    AND instr(substr(gloss, 1, 3), char(13)) = 0
  LIMIT 1;" 2>/dev/null || true)"
  ANSWERS="$(sqlite3 "${PREPARED_JM}" "SELECT count(*) FROM ${FTS_TABLE_NAME} WHERE ${FTS_TABLE_NAME} MATCH '\"${PROBE}\"';" 2>/dev/null || true)"
  if [[ -z "${PROBE}" || "${ANSWERS}" == "0" || -z "${ANSWERS}" ]]; then
    echo "  indexing $PREPARED_JM"
    cp "${DEV_DB}" "${PREPARED_JM}"
  fi
else
  echo "ERROR: ${DEV_DB} is missing or empty; run scripts/build_dictionary.sh" >&2
  exit 1
fi
