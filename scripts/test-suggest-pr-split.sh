#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/suggest-pr-split.sh"
# Source for unit tests of the pure path predicates (main() is BASH_SOURCE-guarded).
# shellcheck source=suggest-pr-split.sh
source "$SCRIPT"

passes=0
failures=0

pass() { passes=$((passes + 1)); }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

assert_eq() {
    local description="$1" expected="$2" actual="$3"
    [ "$expected" = "$actual" ] && pass || fail "$description (expected '$expected', got '$actual')"
}

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

group_count() { printf '%s' "$1" | grep -o '"id":"' | wc -l | tr -d ' '; }

new_repo() {
    local repo
    repo="$(mktemp -d "${TMPDIR:-/tmp}/suggest-pr-split.XXXXXX")"
    git -C "$repo" init -q
    git -C "$repo" config user.name "Test User"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config rerere.enabled false
    echo "$repo"
}

# --- unit: layer classification (pure) -------------------------------------
test_layer_classification() {
    assert_eq "migration layer" migration "$(classify_layer db/migrate/001_init.rb)"
    assert_eq "test layer" test "$(classify_layer src/__tests__/a.test.ts)"
    assert_eq "ui layer (component dir)" ui "$(classify_layer src/ui/Button.tsx)"
    assert_eq "ui layer (asset)" ui "$(classify_layer assets/logo.svg)"
    assert_eq "config layer" config "$(classify_layer config/app.yml)"
    assert_eq "source layer" source "$(classify_layer src/svc/charge.ts)"
    assert_eq "lockfile layer" lockfile "$(classify_layer Cargo.lock)"
    assert_eq "generated layer" generated "$(classify_layer api/user.pb.go)"
}

# --- unit: module clustering (pure) ----------------------------------------
test_module_clustering_unit() {
    assert_eq "monorepo container clusters two segments" src/auth "$(top_module src/auth/a.ts)"
    assert_eq "plain top dir clusters one segment" db "$(top_module db/migrate/001.sql)"
    assert_eq "packages container" packages/ui "$(top_module packages/ui/c.tsx)"
    assert_eq "root file" "(root)" "$(top_module README.md)"
}

# --- integration: layer separation within one module -> medium -------------
test_layer_separation() {
    local repo b out rc
    repo="$(new_repo)"
    mkdir -p "$repo/core/db/migrate"
    printf 'x\n' > "$repo/core/seed.txt"
    git -C "$repo" add -A; git -C "$repo" commit -qm base
    b="$(git -C "$repo" rev-parse HEAD)"
    printf 'CREATE TABLE t;\n' > "$repo/core/db/migrate/001.sql"
    printf 'export const logic = 1\n' > "$repo/core/logic.ts"
    git -C "$repo" add -A; git -C "$repo" commit -qm head
    rc=0
    out="$(cd "$repo" && bash "$SCRIPT" --base "$b" --head HEAD --json)" || rc=$?
    assert_exit "layer separation exits 0" 0 "$rc"
    assert_eq "single module group" 1 "$(group_count "$out")"
    assert_contains "group is medium confidence" '"confidence":"medium"' "$out"
    assert_contains "migration layer present" '"layer":"migration"' "$out"
    rm -rf "$repo"
}

# --- integration: pure rename isolated into refactor-baseline (R100) --------
test_refactor_isolation_R100() {
    local repo b out
    repo="$(new_repo)"
    printf 'a\nb\nc\n' > "$repo/old.ts"
    git -C "$repo" add -A; git -C "$repo" commit -qm base
    b="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" mv old.ts new.ts
    git -C "$repo" commit -qm head
    out="$(cd "$repo" && bash "$SCRIPT" --base "$b" --head HEAD --json)"
    assert_contains "refactor-baseline group" '"id":"refactor-baseline"' "$out"
    assert_contains "refactor order 0" '"order":0' "$out"
    assert_contains "rename status R100" '"status":"R100"' "$out"
    assert_contains "refactor-baseline high confidence" '"confidence":"high"' "$out"
    rm -rf "$repo"
}

# --- integration: sub-threshold rename -> low confidence, not isolated ------
test_low_confidence_rename() {
    local repo b out
    repo="$(new_repo)"
    mkdir -p "$repo/src/svc"
    seq 1 20 > "$repo/src/svc/a.ts"
    git -C "$repo" add -A; git -C "$repo" commit -qm base
    b="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" mv src/svc/a.ts src/svc/b.ts
    { echo X; echo Y; echo Z; echo W; seq 5 20; } > "$repo/src/svc/b.ts"
    git -C "$repo" add -A; git -C "$repo" commit -qm head
    out="$(cd "$repo" && bash "$SCRIPT" --base "$b" --head HEAD --json)"
    assert_contains "weak rename group is low" '"confidence":"low"' "$out"
    assert_not_contains "weak rename not isolated" '"id":"refactor-baseline"' "$out"
    rm -rf "$repo"
}

# --- integration: multi-module clustering ----------------------------------
test_multi_module_clustering() {
    local repo b out
    repo="$(new_repo)"
    printf 'seed\n' > "$repo/seed.txt"
    git -C "$repo" add -A; git -C "$repo" commit -qm base
    b="$(git -C "$repo" rev-parse HEAD)"
    mkdir -p "$repo/src/auth" "$repo/src/billing" "$repo/packages/ui"
    printf 'a\n' > "$repo/src/auth/a.ts"
    printf 'b\n' > "$repo/src/billing/b.ts"
    printf 'c\n' > "$repo/packages/ui/c.tsx"
    git -C "$repo" add -A; git -C "$repo" commit -qm head
    out="$(cd "$repo" && bash "$SCRIPT" --base "$b" --head HEAD --json)"
    assert_eq "three module groups" 3 "$(group_count "$out")"
    assert_contains "src/auth group" '"id":"src/auth"' "$out"
    assert_contains "src/billing group" '"id":"src/billing"' "$out"
    assert_contains "packages/ui group" '"id":"packages/ui"' "$out"
    rm -rf "$repo"
}

# --- integration: cross-cutting module (3 layers) -> low + warning ----------
test_cross_cutting_low_conf() {
    local repo b out
    repo="$(new_repo)"
    mkdir -p "$repo/app/db/migrate" "$repo/app/ui"
    printf 'one\n' > "$repo/app/db/migrate/001.sql"
    printf 'export const s=1\n' > "$repo/app/service.ts"
    printf 'export default 1\n' > "$repo/app/ui/View.tsx"
    git -C "$repo" add -A; git -C "$repo" commit -qm base
    b="$(git -C "$repo" rev-parse HEAD)"
    printf 'one\ntwo\n' > "$repo/app/db/migrate/001.sql"
    printf 'export const s=2\n' > "$repo/app/service.ts"
    printf 'export default 2\n' > "$repo/app/ui/View.tsx"
    git -C "$repo" add -A; git -C "$repo" commit -qm head
    out="$(cd "$repo" && bash "$SCRIPT" --base "$b" --head HEAD --json)"
    assert_contains "cross-cutting module is low" '"confidence":"low"' "$out"
    assert_contains "cross-cutting warning" "is cross-cutting" "$out"
    rm -rf "$repo"
}

# --- integration: large-LOC warning ----------------------------------------
test_large_loc_warning() {
    local repo b out
    repo="$(new_repo)"
    printf 'seed\n' > "$repo/seed.txt"
    git -C "$repo" add -A; git -C "$repo" commit -qm base
    b="$(git -C "$repo" rev-parse HEAD)"
    mkdir -p "$repo/svc"
    seq 1 100 > "$repo/svc/big.ts"
    git -C "$repo" add -A; git -C "$repo" commit -qm head
    out="$(cd "$repo" && bash "$SCRIPT" --base "$b" --head HEAD --large-loc 50 --json)"
    assert_contains "over_large_loc flagged" '"over_large_loc":true' "$out"
    assert_contains "large-loc warning" "exceeds 50 LOC" "$out"
    rm -rf "$repo"
}

# --- integration: empty input ----------------------------------------------
test_empty_input() {
    local repo rc out
    repo="$(new_repo)"
    printf 'x\n' > "$repo/f.txt"
    git -C "$repo" add -A; git -C "$repo" commit -qm base
    rc=0
    out="$(cd "$repo" && bash "$SCRIPT" --base HEAD --head HEAD)" || rc=$?
    assert_exit "empty range exits 1" 1 "$rc"
    assert_contains "empty message" "No changes to split." "$out"
    rm -rf "$repo"
}

# --- integration: non-repo guard -------------------------------------------
test_non_repo_guard() {
    local dir rc err
    dir="$(mktemp -d "${TMPDIR:-/tmp}/suggest-pr-split-norepo.XXXXXX")"
    rc=0
    err="$(cd "$dir" && bash "$SCRIPT" --base x --head y 2>&1)" || rc=$?
    assert_exit "non-repo exits 11" 11 "$rc"
    assert_contains "non-repo message" "not in a git repository" "$err"
    rm -rf "$dir"
}

# --- integration: arg errors -----------------------------------------------
test_arg_errors() {
    local repo rc
    repo="$(new_repo)"
    printf 'x\n' > "$repo/f.txt"; git -C "$repo" add -A; git -C "$repo" commit -qm base
    rc=0; (cd "$repo" && bash "$SCRIPT" --rename-threshold) >/dev/null 2>&1 || rc=$?
    assert_exit "missing flag value exits 10" 10 "$rc"
    rc=0; (cd "$repo" && bash "$SCRIPT" --bogus) >/dev/null 2>&1 || rc=$?
    assert_exit "unknown flag exits 10" 10 "$rc"
    rc=0; (cd "$repo" && bash "$SCRIPT" --rename-threshold abc) >/dev/null 2>&1 || rc=$?
    assert_exit "non-integer threshold exits 10" 10 "$rc"
    rm -rf "$repo"
}

# --- integration: json shape -----------------------------------------------
test_json_shape() {
    local repo b out
    repo="$(new_repo)"
    printf 'seed\n' > "$repo/seed.txt"; git -C "$repo" add -A; git -C "$repo" commit -qm base
    b="$(git -C "$repo" rev-parse HEAD)"
    mkdir -p "$repo/src/a"; printf 'x\n' > "$repo/src/a/x.ts"
    git -C "$repo" add -A; git -C "$repo" commit -qm head
    out="$(cd "$repo" && bash "$SCRIPT" --base "$b" --head HEAD --json)"
    assert_contains "json has mode" '"mode":"range"' "$out"
    assert_contains "json has scope null" '"scope":null' "$out"
    assert_contains "json has groups array" '"groups":[' "$out"
    if command -v python3 >/dev/null 2>&1; then
        if printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
required = {"mode", "scope", "base", "head", "thresholds", "groups", "warnings"}
assert required <= set(d), d.keys()
assert isinstance(d["thresholds"]["rename"], int)
assert isinstance(d["thresholds"]["large_loc"], int)
assert isinstance(d["groups"], list) and d["groups"]
g = d["groups"][0]
for key in ("id", "order", "module", "layer", "confidence", "loc", "over_large_loc", "warnings", "files"):
    assert key in g, key
assert isinstance(g["files"], list) and g["files"]
assert {"path", "status", "layer"} <= set(g["files"][0]), g["files"][0]
' >/dev/null 2>&1; then pass; else fail "json contract invalid"; fi
    else
        echo "SKIP: python3 absent, skipping JSON validity check"
        pass
    fi
    rm -rf "$repo"
}

# --- integration: active conflict scopes ------------------------------------
test_conflict_scopes() {
    local repo out_unmerged out_incoming out_both rc
    repo="$(new_repo)"
    git -C "$repo" branch -M main
    mkdir -p "$repo/src/auth"
    printf 'base\n' > "$repo/conflict.txt"
    printf 'seed\n' > "$repo/src/auth/existing.ts"
    git -C "$repo" add -A; git -C "$repo" commit -qm base
    git -C "$repo" switch -c feature -q
    printf 'feature\n' > "$repo/conflict.txt"
    printf 'new\n' > "$repo/src/auth/new.ts"
    git -C "$repo" add -A; git -C "$repo" commit -qm feature
    git -C "$repo" switch main -q
    printf 'main\n' > "$repo/conflict.txt"
    git -C "$repo" add -A; git -C "$repo" commit -qm main
    (cd "$repo" && git merge feature >/dev/null 2>&1) || true

    rc=0
    out_unmerged="$(cd "$repo" && bash "$SCRIPT" --conflicts --scope unmerged --json)" || rc=$?
    assert_exit "unmerged scope exits 0" 0 "$rc"
    assert_contains "unmerged scope recorded" '"scope":"unmerged"' "$out_unmerged"
    assert_contains "unmerged includes conflict path" '"path":"conflict.txt"' "$out_unmerged"
    assert_not_contains "unmerged excludes non-conflicted incoming file" 'src/auth/new.ts' "$out_unmerged"

    rc=0
    out_incoming="$(cd "$repo" && bash "$SCRIPT" --conflicts --scope incoming-range --json)" || rc=$?
    assert_exit "incoming-range scope exits 0" 0 "$rc"
    assert_contains "incoming scope recorded" '"scope":"incoming-range"' "$out_incoming"
    assert_contains "incoming includes branch-only path" 'src/auth/new.ts' "$out_incoming"

    rc=0
    out_both="$(cd "$repo" && bash "$SCRIPT" --conflicts --scope both --json)" || rc=$?
    assert_exit "both scope exits 0" 0 "$rc"
    assert_contains "both scope warning" "combines incoming range analysis" "$out_both"
    rm -rf "$repo"
}

# --- unit: json_escape handles control chars + named escapes --------------
test_json_escape() {
    assert_eq "newline -> \\n" 'a\nb' "$(json_escape "$(printf 'a\nb')")"
    assert_eq "tab -> \\t" 'a\tb' "$(json_escape "$(printf 'a\tb')")"
    assert_eq "CR -> \\r" 'a\rb' "$(json_escape "$(printf 'a\rb')")"
    assert_eq "BS -> \\b" 'a\bb' "$(json_escape "$(printf 'a\bb')")"
    assert_eq "FF -> \\f" 'a\fb' "$(json_escape "$(printf 'a\fb')")"
    # printf interprets \\u as \u, so the expected output is the literal
    # 8-char string a\u0001b (with a real backslash, not a control char).
    assert_eq "SOH -> \\u0001" "$(printf 'a\\u0001b')" "$(json_escape "$(printf 'a\x01b')")"
    assert_eq "US 0x1f -> \\u001f" "$(printf 'a\\u001fb')" "$(json_escape "$(printf 'a\x1fb')")"
    assert_eq "quote -> \\\"" 'he said \"hi\"' "$(json_escape 'he said "hi"')"
    assert_eq "backslash -> \\\\" 'a\\b' "$(json_escape 'a\b')"
    assert_eq "plain pass-through" 'src/auth/charge.ts' "$(json_escape 'src/auth/charge.ts')"
}

test_json_escape
test_layer_classification
test_module_clustering_unit
test_layer_separation
test_refactor_isolation_R100
test_low_confidence_rename
test_multi_module_clustering
test_cross_cutting_low_conf
test_large_loc_warning
test_empty_input
test_non_repo_guard
test_arg_errors
test_json_shape
test_conflict_scopes

echo ""
echo "Results: $passes passed, $failures failed"
[ "$failures" -eq 0 ]
