#!/usr/bin/env bash
# Measures the Debug build time of Limpid so the cost of growing the Rust
# workspace can be compared against a recorded baseline.
#
# Reported figures:
#   clean        `make clean` followed by `make build`, median of three runs
#   incremental  `make build` after touching one Swift file, median of three
#   cargo        the Rust bridge alone in a scratch target dir, one cold run
#                and one no-op run
#
# The cargo figure is measured directly instead of instrumenting
# scripts/build-rust-bridge.sh so the script under test is not modified.
set -euo pipefail
cd "$(dirname "$0")/.."

touched_file="Limpid/Core/Logging/LimpidLogger.swift"
runs="${LIMPID_MEASURE_RUNS:-3}"
# Filled by `timed` through `printf -v`.
elapsed=""
cargo_cold=""
cargo_noop=""

now() { python3 -c 'import time; print(time.time())'; }

# Stores the wall-clock seconds taken by the command in the named variable,
# rounded to 0.1 s, and stops the script when the command failed. The status
# is checked here rather than through `errexit`, which does not reach into a
# command substitution; a failed build must never be recorded as a timing.
timed() {
  local variable="$1" started
  shift
  started="$(now)"
  "$@" >/dev/null 2>&1 || { echo "error: $* failed" >&2; exit 1; }
  printf -v "$variable" '%s' "$(python3 -c "import time; print(round(time.time() - $started, 1))")"
}

median() {
  printf '%s\n' "$@" | sort -n | awk '{ values[NR] = $1 } END { print values[int((NR + 1) / 2)] }'
}

if [[ -n "$(git status --porcelain -- "$touched_file")" ]]; then
  echo "error: $touched_file has local changes; the incremental run restores it with git checkout" >&2
  exit 1
fi

clean_times=()
for _ in $(seq "$runs"); do
  make clean >/dev/null 2>&1
  timed elapsed make build
  clean_times+=("$elapsed")
done

incremental_times=()
for _ in $(seq "$runs"); do
  printf '\n' >> "$touched_file"
  timed elapsed make build
  git checkout -- "$touched_file"
  incremental_times+=("$elapsed")
done

cargo_target="$(mktemp -d)"
trap 'rm -rf "$cargo_target"' EXIT
export CARGO_TARGET_DIR="$cargo_target"
timed cargo_cold cargo build --locked --package limpid-rust-bridge --target aarch64-apple-darwin
timed cargo_noop cargo build --locked --package limpid-rust-bridge --target aarch64-apple-darwin

echo "runs: $runs"
echo "clean (s):        ${clean_times[*]} -> median $(median "${clean_times[@]}")"
echo "incremental (s):  ${incremental_times[*]} -> median $(median "${incremental_times[@]}")"
echo "cargo cold (s):   $cargo_cold"
echo "cargo no-op (s):  $cargo_noop"
