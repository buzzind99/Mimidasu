#!/usr/bin/env bash
#
# Shared packaging helpers sourced by scripts/package.sh (DMG) and
# scripts/package_mas.sh (Mac App Store).
#
# The caller must set:
#   REPO_ROOT      absolute repo root
#   SIGN_IDENTITY  codesign identity ("Mimidasu Dev", ad-hoc "-", or
#                  "Apple Distribution: …" for MAS)
# and may set:
#   CS_HARDEN      array of extra codesign flags (e.g. --timestamp)
#
# Not executable on its own.

jmdict_pin_tag() {
  sed -n 's/.*static let releaseTag = "\(.*\)"/\1/p' "${REPO_ROOT}/Mimidasu/Dictionary/JMDictPin.swift" | head -1
}

# Fail before spending build time when any runtime artifact is absent. A
# package without the ASR runtime runs as the labeled mock (Guideline 2.1, app
# completeness) and one without the dictionary can never start a session, so
# neither should ever be produced by a packaging step.
require_runtime_artifacts() {
  local ok=1 tag
  if [[ ! -f "${REPO_ROOT}/local/frameworks/libdictionary.dylib" ]]; then
    echo "ERROR: dictionary runtime not built. Run scripts/build_dictionary.sh first." >&2
    ok=0
  fi
  if [[ ! -f "${REPO_ROOT}/local/dictionaries/ipadic-mecab-2_7_0/system.dic.zst" ]]; then
    echo "ERROR: system.dic.zst not fetched. Run scripts/build_dictionary.sh first." >&2
    ok=0
  fi
  tag="$(jmdict_pin_tag)"
  if [[ -z "${tag}" || ! -f "${REPO_ROOT}/local/dictionaries/jmdict-${tag}.sqlite.zst" ]]; then
    echo "ERROR: jmdict-${tag:-<tag>}.sqlite.zst not built. Run scripts/build_jmdict.sh first." >&2
    ok=0
  fi
  if [[ ! -d "${REPO_ROOT}/local/frameworks/crispasr" ]]; then
    echo "ERROR: ASR runtime not built. Run scripts/build_runtime.sh first." >&2
    ok=0
  fi
  (( ok )) || exit 1
}

# Copy the runtime dylibs and bundled model data into the app bundle and sign
# every nested Mach-O with SIGN_IDENTITY.
stage_runtime() {
  local app="$1"
  require_runtime_artifacts

  local fwdir="${app}/Contents/Frameworks"
  local resdir="${app}/Contents/Resources"
  mkdir -p "${fwdir}" "${resdir}"

  # Dictionary tokenizer dylib — independent of the ASR runtime. Without it
  # the bundled dictionary model can never be decompressed.
  cp -f "${REPO_ROOT}/local/frameworks/libdictionary.dylib" "${fwdir}/libdictionary.dylib"
  codesign --force --sign "${SIGN_IDENTITY}" ${CS_HARDEN[@]+"${CS_HARDEN[@]}"} "${fwdir}/libdictionary.dylib"

  # Bundled dictionary model — decompressed once on first launch (never
  # bundled decompressed, never downloaded).
  cp -f "${REPO_ROOT}/local/dictionaries/ipadic-mecab-2_7_0/system.dic.zst" "${resdir}/system.dic.zst"

  # JMDict lookup DB — versioned by pin tag (Mimidasu/Dictionary/JMDictPin.swift,
  # produced by scripts/build_jmdict.sh). The versioned filename is the
  # staleness key: a new pin ships a new file; the stale one is inert.
  local jmdict_tag
  jmdict_tag="$(jmdict_pin_tag)"
  cp -f "${REPO_ROOT}/local/dictionaries/jmdict-${jmdict_tag}.sqlite.zst" "${resdir}/jmdict-${jmdict_tag}.sqlite.zst"

  # The CrispASR dylib set is self-contained (its dylibs resolve their own
  # @rpath dependencies via a @loader_path RPATH), so it bundles as a plain
  # subdirectory of Contents/Frameworks.
  cp -R "${REPO_ROOT}/local/frameworks/crispasr" "${fwdir}/crispasr"
  # The upstream `crispasr` CLI is never exec'd by the app and links Homebrew
  # dylibs (/opt/homebrew/…) that are not bundled — drop it so no shipped
  # binary carries an absolute external dependency.
  rm -f "${fwdir}/crispasr/crispasr"

  # Sign nested code with SIGN_IDENTITY. Everything under Contents/Frameworks
  # is a code location, so `codesign --deep`/App Store validation treats even
  # the data-only VAD model there as nested code and requires a signature —
  # sign the .gguf alongside the dylibs. `while read` over process
  # substitution (not a pipeline) keeps `set -e` failures visible instead of
  # swallowing them in a subshell.
  local f
  while IFS= read -r -d '' f; do
    codesign --force --sign "${SIGN_IDENTITY}" ${CS_HARDEN[@]+"${CS_HARDEN[@]}"} "${f}"
  done < <(find "${fwdir}/crispasr" -type f \( -name "*.dylib" -o -name "*.gguf" \) -print0)
}

# Ship the third-party license notices next to the bundled data.
stage_notices() {
  local app="$1"
  local resdir="${app}/Contents/Resources"
  mkdir -p "${resdir}"
  cp -f "${REPO_ROOT}/THIRD_PARTY_NOTICES.md" "${resdir}/THIRD_PARTY_NOTICES.txt"
}
