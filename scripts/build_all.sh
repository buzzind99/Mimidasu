#!/usr/bin/env bash
#
# Run every build_*.sh producer in dependency-free order so a fresh checkout
# ends up with all local/ runtime artifacts the app and package.sh need.
#
#   scripts/build_all.sh
#
# Steps (each is idempotent and fast-paths when its artifacts are current):
#   1. scripts/build_runtime.sh     ASR runtime (libcrispasr.dylib)
#   2. scripts/build_tokenizer.sh   tokenizer dylib (libdictionary.dylib) + IPADIC
#   3. scripts/build_dictionary.sh  JMDict/JMnedict lookup DB
#
# The list is explicit, not a build_*.sh glob — the glob would match this
# script itself.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -gt 0 ]]; then
  echo "ERROR: build_all.sh takes no arguments (run the individual scripts for flags)" >&2
  exit 1
fi

cd "${REPO_ROOT}"

for script in scripts/build_runtime.sh scripts/build_tokenizer.sh scripts/build_dictionary.sh; do
  echo "==> ${script}"
  "${script}"
done

echo
echo "All build steps complete."
