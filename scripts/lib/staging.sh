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
    echo "ERROR: dictionary runtime not built. Run scripts/build_tokenizer.sh first." >&2
    ok=0
  fi
  if [[ ! -f "${REPO_ROOT}/local/dictionaries/ipadic-mecab-2_7_0/system.dic.zst" ]]; then
    echo "ERROR: system.dic.zst not fetched. Run scripts/build_tokenizer.sh first." >&2
    ok=0
  fi
  tag="$(jmdict_pin_tag)"
  if [[ -z "${tag}" || ! -f "${REPO_ROOT}/local/dictionaries/jmdict-${tag}.sqlite.zst" ]]; then
    echo "ERROR: jmdict-${tag:-<tag>}.sqlite.zst not built. Run scripts/build_dictionary.sh first." >&2
    ok=0
  fi
  if [[ ! -d "${REPO_ROOT}/local/frameworks/crispasr" ]]; then
    echo "ERROR: ASR runtime not built. Run scripts/build_runtime.sh first." >&2
    ok=0
  fi
  (( ok )) || exit 1
}

# App Store upload validation rejects any package file that carries the
# com.apple.quarantine extended attribute (error 91109). Browser-downloaded
# inputs — the provisioning profile above all — pick the attribute up, and
# plain `cp` preserves it. Targeted deletion only: a blanket `xattr -c` would
# also try (and fail) to drop the system-managed com.apple.provenance.
strip_quarantine() {
  local app="$1"
  xattr -dr com.apple.quarantine "${app}" 2>/dev/null || true
}

# Hard gate after staging: a quarantine attribute that survives into the
# artifact fails the upload late (Transporter / App Store Connect), so fail
# here instead, listing the offending paths.
require_no_quarantine() {
  local app="$1" hits
  hits="$(xattr -r "${app}" 2>/dev/null | grep ': com.apple.quarantine$' | sed 's/: com.apple.quarantine$//' || true)"
  if [[ -n "${hits}" ]]; then
    echo "ERROR: quarantined files remain in the bundle:" >&2
    sed 's/^/  /' <<<"${hits}" >&2
    echo "  Strip with: xattr -dr com.apple.quarantine \"${app}\"" >&2
    exit 1
  fi
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
  # produced by scripts/build_dictionary.sh). The versioned filename is the
  # staleness key: a new pin ships a new file; the stale one is inert.
  local jmdict_tag
  jmdict_tag="$(jmdict_pin_tag)"
  cp -f "${REPO_ROOT}/local/dictionaries/jmdict-${jmdict_tag}.sqlite.zst" "${resdir}/jmdict-${jmdict_tag}.sqlite.zst"

  # The CrispASR dylib set is self-contained (its dylibs resolve their own
  # @rpath dependencies via a @loader_path RPATH), so it bundles as a plain
  # subdirectory of Contents/Frameworks — found at release time via the app's
  # `@executable_path/../Frameworks/crispasr` rpath (project.yml). Ship only
  # what the load commands name: the app dlopens `libcrispasr.dylib` and the
  # set loads the `.0` ggml names — the dev prefix additionally carries
  # versioned alias copies (`.1`, `.0.17.0`, `.0.8.30`, unversioned) and an
  # unused `libwhisper.dylib`/CLI that would double the bundle for no benefit.
  local crispasr_dir="${fwdir}/crispasr"
  mkdir -p "${crispasr_dir}"
  local shipped
  for shipped in libcrispasr.dylib libggml.0.dylib libggml-base.0.dylib \
    libggml-cpu.0.dylib libggml-metal.0.dylib libggml-blas.0.dylib \
    firered-vad.gguf; do
    if [[ ! -f "${REPO_ROOT}/local/frameworks/crispasr/${shipped}" ]]; then
      echo "ERROR: ${shipped} missing from local/frameworks/crispasr. Run scripts/build_runtime.sh first." >&2
      if [[ "${shipped}" == libggml-metal.0.dylib ]]; then
        echo "       (--cpu runtime builds don't produce it — package with the default Metal build)" >&2
      fi
      exit 1
    fi
    cp -f "${REPO_ROOT}/local/frameworks/crispasr/${shipped}" "${crispasr_dir}/${shipped}"
  done

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

# Ship the third-party license notices next to the bundled data, plus the
# license governing this channel: DMG builds ship AGPL (LICENSE.md), App
# Store builds ship the Apple Standard EULA notice (LICENSE-MAS.md).
stage_notices() {
  local app="$1" license="$2"
  local resdir="${app}/Contents/Resources"
  mkdir -p "${resdir}"
  cp -f "${REPO_ROOT}/THIRD_PARTY_NOTICES.md" "${resdir}/THIRD_PARTY_NOTICES.txt"
  cp -f "${REPO_ROOT}/${license}" "${resdir}/${license%.md}.txt"
}
