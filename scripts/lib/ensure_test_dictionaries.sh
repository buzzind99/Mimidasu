#!/bin/zsh
#   scripts/lib/ensure_test_dictionaries.sh
#
# Makes the dictionary-backed tests self-sufficient in a fresh checkout.
# Everything stays inside the repo — tests never touch
# ~/Library/Application Support (debug builds resolve and prepare inside
# the gitignored build/ tree):
#
#   1. local/ runtime artifacts: builds whatever is missing via
#      build_dictionary.sh (libdictionary.dylib + tokenizer model) and
#      build_jmdict.sh (pinned JMDict database).
#   2. build/prepared/dictionaries: seeds the prepared artifacts debug
#      builds resolve, decompressing through the same dylib FFI the app
#      uses. Without the seed the first test run would race the test host
#      app's background first-launch prepare.
set -euo pipefail
cd "$(dirname "$0")/../.."

DYLIB="local/frameworks/libdictionary.dylib"
MODEL_ZST="local/dictionaries/ipadic-mecab-2_7_0/system.dic.zst"
PREPARED="build/prepared/dictionaries"
PIN_SWIFT="Mimidasu/Dictionary/JMDictPin.swift"
PIN_TAG=$(python3 -c 'import re, sys; print(re.search(r"releaseTag\s*=\s*\"([^\"]+)\"", open(sys.argv[1]).read()).group(1))' "$PIN_SWIFT")
JMDICT_ZST="local/dictionaries/jmdict-${PIN_TAG}.sqlite.zst"

if [[ ! -f "$DYLIB" || ! -f "$MODEL_ZST" ]]; then
  echo "  building dictionary runtime + model (scripts/build_dictionary.sh)"
  scripts/build_dictionary.sh
fi
if [[ ! -f "$JMDICT_ZST" ]]; then
  echo "  building JMDict database (scripts/build_jmdict.sh)"
  scripts/build_jmdict.sh
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
seed "$JMDICT_ZST" "$PREPARED/jmdict-${PIN_TAG}.sqlite"
