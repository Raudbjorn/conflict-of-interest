#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/detect-stacked-pr.sh"

passes=0
failures=0

assert_contains() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: $description (missing '$expected')"
        echo "$actual"
        failures=$((failures + 1))
    fi
}

run_input() {
    bash "$SCRIPT" "$@" 2>/dev/null
}

auto_block='<<<<<<< HEAD
const value = one();
||||||| base
=======
const value = one();
>>>>>>> theirs'

ask_block='<<<<<<< HEAD
a
b
c
||||||| base
=======
a
b
d
>>>>>>> theirs'

diverge_block='<<<<<<< HEAD
a
b
||||||| base
=======
x
y
>>>>>>> theirs'

standard_block='<<<<<<< HEAD
a
||||||| base
base
=======
a
>>>>>>> theirs'

two_way_block='<<<<<<< HEAD
a
=======
a
>>>>>>> theirs'

out="$(printf '%s\n' "$auto_block" | run_input --json)"
assert_contains "auto block json" '"verdict":"AUTO_HEAD"' "$out"
assert_contains "auto block similarity" '"similarity":100' "$out"

out="$(printf '%s\n' "$ask_block" | run_input --json --auto 95 --ask 50)"
assert_contains "ask block" '"verdict":"ASK"' "$out"

out="$(printf '%s\n' "$diverge_block" | run_input --json)"
assert_contains "diverge block" '"verdict":"DIVERGE"' "$out"

out="$(printf '%s\n' "$standard_block" | run_input --json)"
assert_contains "non-empty base" '"verdict":"NON_EMPTY_BASE"' "$out"

out="$(printf '%s\n' "$two_way_block" | run_input --json)"
assert_contains "no diff3" '"verdict":"NO_DIFF3"' "$out"

tmp="$(mktemp "${TMPDIR:-/tmp}/stacked.XXXXXX")"
printf '%s\n' "$auto_block" > "$tmp"
out="$(bash "$SCRIPT" --file "$tmp")"
assert_contains "file mode reports auto" 'AUTO_HEAD' "$out"
rm -f "$tmp"

rc=0
printf 'no conflicts\n' | bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then passes=$((passes + 1)); else echo "FAIL: no blocks exits 1"; failures=$((failures + 1)); fi

echo ""
echo "Results: $passes passed, $failures failed"
[ "$failures" -eq 0 ]

