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

jmdict_artifact_tag() {
  # releaseTag + "." + buildRevision — the artifact name keys on both (see
  # scripts/build_dictionary.sh's ARTIFACT_TAG).
  local pin_swift="${REPO_ROOT}/Mimidasu/Dictionary/JMDictPin.swift"
  local tag rev
  tag="$(sed -n 's/.*static let releaseTag = "\(.*\)"/\1/p' "${pin_swift}" | head -1)"
  rev="$(sed -n 's/.*static let buildRevision = "\(.*\)"/\1/p' "${pin_swift}" | head -1)"
  if [[ -z "${tag}" || -z "${rev}" ]]; then
    echo "ERROR: cannot extract releaseTag/buildRevision from ${pin_swift}; update this helper." >&2
    return 1
  fi
  printf '%s.%s\n' "${tag}" "${rev}"
}

# Every file stage_runtime copies out of local/frameworks/crispasr. The
# pre-build gate and the staging loop share this list so the gate can never
# pass something staging will later reject.
staged_crispasr_files() {
  printf '%s\n' \
    libcrispasr.dylib \
    libggml.0.dylib \
    libggml-base.0.dylib \
    libggml-cpu.0.dylib \
    libggml-metal.0.dylib \
    libggml-blas.0.dylib \
    firered-vad.gguf
}

# The app-sized runtime is relinked from the dlsym manifest in
# CrispASRLibrary; a stale copy from an older build can exist at the expected
# path and still package. Check the required session exports rather than
# existence alone. Backend detection is deliberately not required: the engine
# falls back to the GGUF file name, so a pre-detection runtime still runs.
app_runtime_has_symbols() {
  local dylib="$1" exported symbol
  exported="$(nm -gU "${dylib}" 2>/dev/null | awk '{print $3}')" || return 1
  [[ -n "${exported}" ]] || return 1
  for symbol in \
    _crispasr_set_gpu_backend \
    _crispasr_session_open_explicit \
    _crispasr_session_close \
    _crispasr_session_transcribe_lang \
    _crispasr_session_result_n_segments \
    _crispasr_session_result_segment_text \
    _crispasr_session_result_free; do
    grep -qx "${symbol}" <<<"${exported}" || return 1
  done
}

# Fail before spending build time when any runtime artifact is absent. A
# package without the ASR runtime runs as the labeled mock (Guideline 2.1, app
# completeness) and one without the dictionary can never start a session, so
# neither should ever be produced by a packaging step.
require_runtime_artifacts() {
  local ok=1 artifact_tag
  local crispasr_dir="${REPO_ROOT}/local/frameworks/crispasr"
  local shipped source
  if [[ ! -f "${REPO_ROOT}/local/frameworks/libdictionary.dylib" ]]; then
    echo "ERROR: dictionary runtime not built. Run scripts/build_tokenizer.sh first." >&2
    ok=0
  fi
  if [[ ! -f "${REPO_ROOT}/local/dictionaries/ipadic-mecab-2_7_0/system.dic.zst" ]]; then
    echo "ERROR: system.dic.zst not fetched. Run scripts/build_tokenizer.sh first." >&2
    ok=0
  fi
  artifact_tag="$(jmdict_artifact_tag)"
  if [[ ! -f "${REPO_ROOT}/local/dictionaries/jmdict-${artifact_tag}.sqlite.zst" ]]; then
    echo "ERROR: jmdict-${artifact_tag}.sqlite.zst not built. Run scripts/build_dictionary.sh first." >&2
    ok=0
  fi
  if [[ ! -d "${crispasr_dir}" ]]; then
    echo "ERROR: ASR runtime not built. Run scripts/build_runtime.sh first." >&2
    ok=0
  else
    while IFS= read -r shipped; do
      source="${crispasr_dir}/${shipped}"
      if [[ "${shipped}" == libcrispasr.dylib ]]; then
        source="${crispasr_dir}/libcrispasr-app.dylib"
        if [[ ! -f "${source}" ]]; then
          echo "ERROR: app-sized ASR runtime missing. Re-run scripts/build_runtime.sh." >&2
          ok=0
          continue
        fi
      fi
      if [[ ! -f "${source}" ]]; then
        echo "ERROR: ${shipped} missing from ${crispasr_dir}. Run scripts/build_runtime.sh first." >&2
        if [[ "${shipped}" == libggml-metal.0.dylib ]]; then
          echo "       (--cpu runtime builds don't produce it — package with the default Metal build)" >&2
        fi
        ok=0
      fi
    done < <(staged_crispasr_files)
    if [[ -f "${crispasr_dir}/libcrispasr-app.dylib" ]] \
      && ! app_runtime_has_symbols "${crispasr_dir}/libcrispasr-app.dylib"; then
      echo "ERROR: app-sized ASR runtime is stale or incomplete. Re-run scripts/build_runtime.sh." >&2
      ok=0
    fi
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
  # the bundled dictionary model can never be decompressed. The local build
  # keeps its symbols; the shipped copy does not need them.
  cp -f "${REPO_ROOT}/local/frameworks/libdictionary.dylib" "${fwdir}/libdictionary.dylib"
  strip -x "${fwdir}/libdictionary.dylib"
  codesign --force --sign "${SIGN_IDENTITY}" ${CS_HARDEN[@]+"${CS_HARDEN[@]}"} "${fwdir}/libdictionary.dylib"

  # Bundled dictionary model — decompressed once on first launch (never
  # bundled decompressed, never downloaded).
  cp -f "${REPO_ROOT}/local/dictionaries/ipadic-mecab-2_7_0/system.dic.zst" "${resdir}/system.dic.zst"

  # JMDict lookup DB — versioned by pin tag + build revision
  # (Mimidasu/Dictionary/JMDictPin.swift, produced by
  # scripts/build_dictionary.sh). The versioned filename is the staleness
  # key: a new pin or a new ingestion recipe ships a new file; the stale one
  # is inert.
  local tag
  tag="$(jmdict_artifact_tag)"
  cp -f "${REPO_ROOT}/local/dictionaries/jmdict-${tag}.sqlite.zst" \
    "${resdir}/jmdict-${tag}.sqlite.zst"

  # The CrispASR dylib set is self-contained (its dylibs resolve their own
  # @rpath dependencies via a @loader_path RPATH), so it bundles as a plain
  # subdirectory of Contents/Frameworks — found at release time via the app's
  # `@executable_path/../Frameworks/crispasr` rpath (project.yml). Ship only
  # what the load commands name: the app dlopens `libcrispasr.dylib` and the
  # set loads the `.0` ggml names — the dev prefix additionally carries
  # versioned alias copies and an unused `libwhisper.dylib`/CLI that would
  # double the bundle for no benefit.
  local crispasr_dir="${fwdir}/crispasr"
  mkdir -p "${crispasr_dir}"
  local shipped source
  while IFS= read -r shipped; do
    # The shipped libcrispasr is the app-sized relink: the full dylib stays in
    # local/frameworks/crispasr for the CLI/dev runtime. Both resolve their
    # ggml companions from their own directory.
    source="${REPO_ROOT}/local/frameworks/crispasr/${shipped}"
    if [[ "${shipped}" == libcrispasr.dylib ]]; then
      source="${REPO_ROOT}/local/frameworks/crispasr/libcrispasr-app.dylib"
    fi
    if [[ ! -f "${source}" ]]; then
      echo "ERROR: ${shipped} missing from local/frameworks/crispasr. Run scripts/build_runtime.sh first." >&2
      if [[ "${shipped}" == libggml-metal.0.dylib ]]; then
        echo "       (--cpu runtime builds don't produce it — package with the default Metal build)" >&2
      fi
      exit 1
    fi
    cp -f "${source}" "${crispasr_dir}/${shipped}"
    # The VAD model is data; only the Mach-O dylibs carry a symbol table.
    if [[ "${shipped}" == *.dylib ]]; then
      strip -x "${crispasr_dir}/${shipped}"
    fi
  done < <(staged_crispasr_files)

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

# Strip local symbols from the main executable before the bundle is sealed.
# Xcode leaves the Release product unstripped by default here, which roughly
# triples the executable's size; the separate dSYM still symbolicates crashes.
strip_app_binary() {
  local app="$1"
  strip -x "${app}/Contents/MacOS/Mimidasu"
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
