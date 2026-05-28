#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/semantic-audit.sh"

passes=0
failures=0

setup_repo() {
    local repo
    repo="$(mktemp -d "${TMPDIR:-/tmp}/semantic-audit.XXXXXX")"
    git -C "$repo" init -q
    git -C "$repo" config user.name "Test User"
    git -C "$repo" config user.email "test@example.com"
    cat > "$repo/app.py" <<'EOF'
def charge(user):
    return user.total

def main(user):
    return charge(user)
EOF
    git -C "$repo" add app.py
    git -C "$repo" commit -m base -q
    echo "$repo"
}

assert_exit() {
    local description="$1" expected="$2" actual="$3"
    if [ "$expected" -eq "$actual" ]; then
        passes=$((passes + 1))
    else
        echo "FAIL: $description (expected $expected, got $actual)"
        failures=$((failures + 1))
    fi
}

assert_contains() {
    local description="$1" expected="$2" actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: $description (missing '$expected')"
        failures=$((failures + 1))
    fi
}

test_no_active_operation() {
    local repo rc
    repo="$(setup_repo)"
    rc=0
    (cd "$repo" && bash "$SCRIPT") >/dev/null 2>&1 || rc=$?
    assert_exit "no active operation exits 2" 2 "$rc"
    rm -rf "$repo"
}

test_suspect_found_with_refs() {
    local repo base other rc out
    repo="$(setup_repo)"
    base="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" checkout -b ours -q
    cat > "$repo/app.py" <<'EOF'
def charge(user, currency):
    return user.total

def main(user):
    return charge(user, "USD")
EOF
    git -C "$repo" commit -am ours -q
    git -C "$repo" checkout -b theirs "$base" -q
    cat > "$repo/app.py" <<'EOF'
def charge(user):
    return user.total

def audit(user):
    return charge(user)

def main(user):
    return charge(user)
EOF
    git -C "$repo" commit -am theirs -q
    other="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" checkout ours -q
    printf '%s\n' "$other" > "$repo/.git/MERGE_HEAD"
    rc=0
    out="$(cd "$repo" && bash "$SCRIPT" --base "$base" --other "$other" --json)" || rc=$?
    assert_exit "suspect exits 1" 1 "$rc"
    assert_contains "suspect mentions charge" '"symbol":"charge"' "$out"
    rm -rf "$repo"
}

test_no_suspect() {
    local repo base other rc
    repo="$(setup_repo)"
    base="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" checkout -b ours -q
    cat >> "$repo/app.py" <<'EOF'

def helper():
    return 1
EOF
    git -C "$repo" commit -am ours -q
    git -C "$repo" checkout -b theirs "$base" -q
    cat >> "$repo/app.py" <<'EOF'

def unrelated():
    return 2
EOF
    git -C "$repo" commit -am theirs -q
    other="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" checkout ours -q
    rc=0
    (cd "$repo" && bash "$SCRIPT" --base "$base" --other "$other" --json) >/dev/null || rc=$?
    assert_exit "no suspect exits 0" 0 "$rc"
    rm -rf "$repo"
}

test_no_active_operation
test_suspect_found_with_refs
test_no_suspect

echo ""
echo "Results: $passes passed, $failures failed"
[ "$failures" -eq 0 ]

