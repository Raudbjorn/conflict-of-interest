#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/prompt-context.sh"

passes=0
failures=0
pass() { passes=$((passes + 1)); }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
assert_exit() {
    local description="$1" expected="$2" actual="$3"
    [ "$expected" -eq "$actual" ] && pass || fail "$description (expected exit $expected, got $actual)"
}
assert_contains() {
    local description="$1" needle="$2" hay="$3"
    [[ "$hay" == *"$needle"* ]] && pass || fail "$description (missing '$needle')"
}
assert_not_contains() {
    local description="$1" needle="$2" hay="$3"
    [[ "$hay" != *"$needle"* ]] && pass || fail "$description (unexpected '$needle')"
}

new_repo() {
    local repo
    repo="$(mktemp -d "${TMPDIR:-/tmp}/prompt-context.XXXXXX")"
    git -C "$repo" init -q
    git -C "$repo" config user.name "Test User"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config rerere.enabled false
    echo "$repo"
}

# Helper: build a 3-file TS fixture with a known symbol graph and a conflict.
fixture_known_graph() {
    local repo="$1"
    mkdir -p "$repo/src" "$repo/lib"
    cat > "$repo/src/charge.ts" <<'EOF'
import { Customer } from '../lib/customer'
export function charge(c: Customer, amount: number) {
  return c.balance - amount
}
EOF
    cat > "$repo/lib/customer.ts" <<'EOF'
export class Customer { balance: number = 0 }
EOF
    cat > "$repo/src/billing.ts" <<'EOF'
import { charge } from './charge'
export function process() { return charge({} as any, 0) }
EOF
    git -C "$repo" add -A
    git -C "$repo" commit -qm base
    cat > "$repo/src/charge.ts" <<'EOF'
import { Customer } from '../lib/customer'
<<<<<<< HEAD
export function charge(c: Customer, amount: number) {
  return c.balance - amount
}
||||||| base
=======
export function charge(c: Customer, amount: number, currency: string) {
  return { balance: c.balance - amount, currency }
}
>>>>>>> theirs
EOF
}

# 1: auto seed extraction
test_seed_extraction() {
    local repo out
    repo="$(new_repo)"
    fixture_known_graph "$repo"
    out="$(cd "$repo" && bash "$SCRIPT" --file src/charge.ts)"
    assert_contains "seeds: charge" "- \`charge\`" "$out"
    assert_contains "seeds: Customer" "- \`Customer\`" "$out"
    assert_contains "seeds: currency (theirs side)" "- \`currency\`" "$out"
    assert_not_contains "export filtered as noise" "- \`export\`" "$out"
    rm -rf "$repo"
}

# 2: k=1 cross-reference hits
test_k1_hits() {
    local repo out
    repo="$(new_repo)"
    fixture_known_graph "$repo"
    out="$(cd "$repo" && bash "$SCRIPT" --file src/charge.ts)"
    assert_contains "k=1 finds billing.ts" "src/billing.ts" "$out"
    assert_contains "k=1 finds customer.ts" "lib/customer.ts" "$out"
    rm -rf "$repo"
}

# 3: budget enforcement — small max-hits forces truncation
test_budget_truncation() {
    local repo out
    repo="$(new_repo)"
    fixture_known_graph "$repo"
    out="$(cd "$repo" && bash "$SCRIPT" --file src/charge.ts --max-hits 2 --format json)"
    assert_contains "truncated flag set" '"truncated":true' "$out"
    if command -v python3 >/dev/null 2>&1; then
        local hits
        hits="$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["budget"]["hits"])')"
        # hits must be <= max_hits=2
        [ "$hits" -le 2 ] && pass || fail "hits ($hits) exceeded cap (2)"
    else
        pass
    fi
    rm -rf "$repo"
}

# 4: byte budget enforcement
test_byte_budget() {
    local repo out
    repo="$(new_repo)"
    fixture_known_graph "$repo"
    out="$(cd "$repo" && bash "$SCRIPT" --file src/charge.ts --max-bytes 80 --format json)"
    assert_contains "byte budget triggers truncation" '"truncated":true' "$out"
    if command -v python3 >/dev/null 2>&1; then
        local bytes
        bytes="$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["budget"]["bytes"])')"
        [ "$bytes" -le 80 ] && pass || fail "bytes ($bytes) exceeded cap (80)"
    else
        pass
    fi
    rm -rf "$repo"
}

# 5: JSON shape
test_json_shape() {
    local repo out
    repo="$(new_repo)"
    fixture_known_graph "$repo"
    out="$(cd "$repo" && bash "$SCRIPT" --file src/charge.ts --format json)"
    assert_contains "json has file" '"file":"src/charge.ts"' "$out"
    assert_contains "json has seeds" '"seeds":[' "$out"
    assert_contains "json has hops" '"hops":[' "$out"
    assert_contains "json has budget" '"budget":{' "$out"
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$out" | python3 -m json.tool >/dev/null 2>&1 && pass || fail "json invalid"
    else
        pass
    fi
    rm -rf "$repo"
}

# 6: --symbol adds a seed
test_user_symbol() {
    local repo out
    repo="$(new_repo)"
    fixture_known_graph "$repo"
    out="$(cd "$repo" && bash "$SCRIPT" --file src/charge.ts --symbol explicitSeed --format json)"
    assert_contains "user symbol included" '"explicitSeed"' "$out"
    rm -rf "$repo"
}

# 7: no seeds (plain conflict without identifiers)
test_no_seeds() {
    local repo rc out
    repo="$(new_repo)"
    echo seed > "$repo/seed.txt"; git -C "$repo" add -A; git -C "$repo" commit -qm base
    cat > "$repo/plain.txt" <<'EOF'
<<<<<<< HEAD
a
b
c
||||||| base
=======
d
e
f
>>>>>>> theirs
EOF
    rc=0
    out="$(cd "$repo" && bash "$SCRIPT" --file plain.txt --format json)" || rc=$?
    assert_exit "no seeds exits 2" 2 "$rc"
    assert_contains "no seeds empty array" '"seeds":[]' "$out"
    rm -rf "$repo"
}

# 8: arg errors
test_arg_errors() {
    local repo rc
    repo="$(new_repo)"
    echo seed > "$repo/seed.txt"; git -C "$repo" add -A; git -C "$repo" commit -qm base
    rc=0; (cd "$repo" && bash "$SCRIPT") >/dev/null 2>&1 || rc=$?
    assert_exit "missing --file exits 10" 10 "$rc"
    rc=0; (cd "$repo" && bash "$SCRIPT" --bogus) >/dev/null 2>&1 || rc=$?
    assert_exit "unknown flag exits 10" 10 "$rc"
    rc=0; (cd "$repo" && bash "$SCRIPT" --format bogus --file seed.txt) >/dev/null 2>&1 || rc=$?
    assert_exit "bad --format exits 10" 10 "$rc"
    rm -rf "$repo"
}

# 9: non-repo guard
test_non_repo_guard() {
    local dir rc
    dir="$(mktemp -d "${TMPDIR:-/tmp}/prompt-context-norepo.XXXXXX")"
    echo x > "$dir/f.txt"
    rc=0; (cd "$dir" && bash "$SCRIPT" --file f.txt) >/dev/null 2>&1 || rc=$?
    assert_exit "non-repo exits 11" 11 "$rc"
    rm -rf "$dir"
}

# 10: excluded path filters .md files
test_excluded_paths() {
    local repo out
    repo="$(new_repo)"
    fixture_known_graph "$repo"
    # add a doc that mentions our seed; it should NOT show up
    echo "see charge in docs" > "$repo/NOTES.md"
    git -C "$repo" add -A
    out="$(cd "$repo" && bash "$SCRIPT" --file src/charge.ts)"
    assert_not_contains "md files excluded from hits" "NOTES.md" "$out"
    rm -rf "$repo"
}

test_seed_extraction
test_k1_hits
test_budget_truncation
test_byte_budget
test_json_shape
test_user_symbol
test_no_seeds
test_arg_errors
test_non_repo_guard
test_excluded_paths

echo ""
echo "Results: $passes passed, $failures failed"
[ "$failures" -eq 0 ]
