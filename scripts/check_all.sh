#!/usr/bin/env bash
# Runs the listed fast checks in order and prints PASS/FAIL per step plus a summary.
# Optional offline unit tests run only with --with-unit-tests.
# Exit codes: 0 all checks passed, 1 at least one check failed, 2 invalid arguments.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/check_all.sh [--with-unit-tests --ios-destination DEST --tvos-destination DEST --output-dir DIR]

Runs, in order:
  1. swift-format lint (strict) on immichSlides, immichSlidesTests, immichSlidesUITests, TestSupport
  2. test conventions
  3. release guards
  4. localization catalog
  5. localization usage (user-facing literals missing from the string catalog)
  6. Python test prerequisites: Swift, zstd CLI and Pillow (missing tools fail)
  7. Python tests with per-test result records
  8. Optional Xcode offline unit tests for iOS and tvOS (only with --with-unit-tests)

Options:
  --with-unit-tests        Also run scripts/run_offline_unit_tests.py for iOS and tvOS.
  --ios-destination DEST   xcodebuild destination for iOS, e.g. 'platform=iOS Simulator,id=<UDID>'.
  --tvos-destination DEST  xcodebuild destination for tvOS, e.g. 'platform=tvOS Simulator,id=<UDID>'.
  --output-dir DIR         Directory for .xcresult bundles. Must be outside the repository.
  -h, --help               Show this help.

Without --with-unit-tests the Xcode tests are skipped; run them before opening a pull request.
No private configuration is needed.
Every Python step uses "${PYTHON:-python3}", honoring an active venv or pyenv.
Recommend PYTHON=/usr/bin/python3 or a venv created with /usr/bin/python3.
Python 3.14 fixture stall: https://github.com/sudoHG/immichSlides/issues/122
Optional unit-test DerivedData stays in .derivedData/check-all-{ios,tvos}.
EOF
}

die_usage() {
    echo "check_all.sh: $1" >&2
    echo "Run 'scripts/check_all.sh --help' for usage." >&2
    exit 2
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

with_unit_tests=0
ios_destination=""
tvos_destination=""
output_dir=""

while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
        usage
        exit 0
        ;;
    --with-unit-tests)
        with_unit_tests=1
        shift
        ;;
    --ios-destination | --tvos-destination | --output-dir)
        [[ $# -ge 2 && -n "$2" ]] || die_usage "$1 needs a value"
        case "$1" in
        --ios-destination) ios_destination="$2" ;;
        --tvos-destination) tvos_destination="$2" ;;
        --output-dir) output_dir="$2" ;;
        esac
        shift 2
        ;;
    *)
        die_usage "unknown argument: $1"
        ;;
    esac
done

if [[ $with_unit_tests -eq 1 ]]; then
    [[ -n "$ios_destination" ]] || die_usage "--with-unit-tests needs --ios-destination"
    [[ -n "$tvos_destination" ]] || die_usage "--with-unit-tests needs --tvos-destination"
    [[ -n "$output_dir" ]] || die_usage "--with-unit-tests needs --output-dir (outside the repository)"
    mkdir -p "$output_dir"
    output_dir="$(cd "$output_dir" && pwd -P)"
    case "$output_dir/" in
    "$REPO_ROOT"/*) die_usage "--output-dir must be outside the repository: $output_dir" ;;
    esac
elif [[ -n "$ios_destination$tvos_destination$output_dir" ]]; then
    die_usage "--ios-destination, --tvos-destination and --output-dir require --with-unit-tests"
fi

cd "$REPO_ROOT"
python="${PYTHON:-python3}"

step_names=()
step_results=()
failures=0

run_step() {
    local name="$1"
    shift
    local started=$SECONDS
    echo
    echo "==> $name"
    echo "    \$ $*"
    local status=0
    "$@" || status=$?
    local elapsed=$((SECONDS - started))
    step_names+=("$name")
    if [[ $status -eq 0 ]]; then
        step_results+=("PASS (${elapsed}s)")
        echo "PASS: $name (${elapsed}s)"
    else
        step_results+=("FAIL (exit $status, ${elapsed}s)")
        echo "FAIL: $name (exit $status, ${elapsed}s)"
        failures=$((failures + 1))
    fi
}

host_output="$(mktemp -d "${TMPDIR:-/tmp}/immichslides-check-all.XXXXXX")"
trap 'rm -rf "$host_output"' EXIT
run_step "host checks" "$python" -B scripts/run_host_checks.py --output-dir "$host_output"

if [[ $with_unit_tests -eq 1 ]]; then
    stamp="$(date +%Y%m%d-%H%M%S)"
    run_step "xcode unit tests (iOS)" "$python" scripts/run_offline_unit_tests.py \
        --platform ios \
        --destination "$ios_destination" \
        --derived-data-path .derivedData/check-all-ios \
        --result-bundle-path "$output_dir/check-all-ios-$stamp.xcresult"
    run_step "xcode unit tests (tvOS)" "$python" scripts/run_offline_unit_tests.py \
        --platform tvos \
        --destination "$tvos_destination" \
        --derived-data-path .derivedData/check-all-tvos \
        --result-bundle-path "$output_dir/check-all-tvos-$stamp.xcresult"
fi

echo
echo "==> Summary"
for i in "${!step_names[@]}"; do
    printf '  %-26s %s\n' "${step_names[$i]}" "${step_results[$i]}"
done
if [[ $with_unit_tests -eq 0 ]]; then
    printf '  %-26s %s\n' "xcode unit tests" "SKIPPED (not requested)"
    echo "Xcode unit tests were skipped. Run them before opening a pull request:"
    echo "  scripts/check_all.sh --with-unit-tests --ios-destination '<dest>' --tvos-destination '<dest>' --output-dir '<outside-repo>'"
fi

if [[ $failures -gt 0 ]]; then
    echo "RESULT: FAIL ($failures step(s) failed)"
    exit 1
fi
echo "RESULT: PASS"
