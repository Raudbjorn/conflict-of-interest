#!/usr/bin/env bash
set -euo pipefail

# open-stacked-prs.sh — materialize a PR-decomposition plan as a stack of
# branches and stacked GitHub PRs.
#
# OUTWARD-FACING: defaults to dry-run. It only prints the git/gh command plan
# unless --execute is given. The skill procedure must obtain explicit user
# confirmation and show the dry-run plan before passing --execute.
#
# Each group becomes a branch carved from the previous branch (stacked
# topology): group 1 branches off --base, group 2 off group 1, etc. Each PR
# targets its parent branch; retarget to --base as parents merge
# (`gh pr edit <n> --base <base>` / `git rebase --onto`).

GH_BIN="${GH_BIN:-gh}"

command -v git >/dev/null || { echo "ERROR: git not found in PATH" >&2; exit 12; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repository" >&2; exit 11; }

base=""
head_ref="HEAD"
execute=false
allow_dirty=false
draft=false
from_json=false
gnames=()
gpaths=()

add_group() {
    local spec="$1" name rest
    case "$spec" in
        *:*) ;;
        *) echo "ERROR: --group needs 'name:path1,path2,...'" >&2; exit 10 ;;
    esac
    name="${spec%%:*}"
    rest="${spec#*:}"
    [ -n "$name" ] || { echo "ERROR: --group name is empty" >&2; exit 10; }
    [ -n "$rest" ] || { echo "ERROR: --group '$name' has no paths" >&2; exit 10; }
    gnames+=("$name")
    gpaths+=("$rest")
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --base) [ "$#" -ge 2 ] || { echo "ERROR: --base needs a branch" >&2; exit 10; }; base="$2"; shift 2 ;;
        --head) [ "$#" -ge 2 ] || { echo "ERROR: --head needs a ref" >&2; exit 10; }; head_ref="$2"; shift 2 ;;
        --group) [ "$#" -ge 2 ] || { echo "ERROR: --group needs a spec" >&2; exit 10; }; add_group "$2"; shift 2 ;;
        --from-json) from_json=true; shift ;;
        --execute) execute=true; shift ;;
        --allow-dirty) allow_dirty=true; shift ;;
        --draft) draft=true; shift ;;
        --) shift; break ;;
        -*) echo "ERROR: unknown flag: $1" >&2; exit 10 ;;
        *) echo "ERROR: unexpected arg: $1" >&2; exit 10 ;;
    esac
done

# Default base: origin's default branch, else current branch.
if [ -z "$base" ]; then
    base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
    [ -n "$base" ] || base="$(git branch --show-current 2>/dev/null || true)"
    [ -n "$base" ] || { echo "ERROR: cannot determine --base; pass it explicitly" >&2; exit 10; }
fi

# Optional: build groups from suggest-pr-split.sh JSON on stdin.
if $from_json; then
    command -v python3 >/dev/null 2>&1 || { echo "ERROR: --from-json requires python3" >&2; exit 10; }
    while IFS=$'\t' read -r gid paths; do
        [ -n "$gid" ] || continue
        local_branch="split/$(printf '%s' "$gid" | tr -c 'A-Za-z0-9._/-' '-')"
        gnames+=("$local_branch")
        gpaths+=("$paths")
    done < <(python3 -c '
import json, sys
d = json.load(sys.stdin)
for g in d.get("groups", []):
    paths = ",".join(f["path"] for f in g.get("files", []))
    if paths:
        print(g["id"] + "\t" + paths)
' || true)
fi

[ "${#gnames[@]}" -gt 0 ] || { echo "ERROR: no groups given (use --group or --from-json)" >&2; exit 15; }

if $execute && ! $allow_dirty; then
    [ -z "$(git status --porcelain)" ] || { echo "ERROR: working tree is dirty; commit/stash or pass --allow-dirty" >&2; exit 13; }
fi
if $execute; then
    command -v "$GH_BIN" >/dev/null 2>&1 || { echo "ERROR: '$GH_BIN' not found; install GitHub CLI or set GH_BIN" >&2; exit 14; }
fi

run() {
    if $execute; then
        "$@"
    else
        local out="" a
        for a in "$@"; do out+=" $(printf '%q' "$a")"; done
        printf '    %s\n' "${out# }"
    fi
}

if $execute; then
    echo "=== open-stacked-prs (EXECUTE) ==="
else
    echo "=== open-stacked-prs (dry-run; pass --execute to apply) ==="
fi
echo "Base: $base   Source: $head_ref   Groups: ${#gnames[@]}"
echo ""

prev_base="$base"
gh_pr_args=()
$draft && gh_pr_args+=(--draft)

idx=0
for idx in "${!gnames[@]}"; do
    branch="${gnames[$idx]}"
    IFS=',' read -ra paths <<< "${gpaths[$idx]}"
    title="$branch"
    body="Stacked PR carved from ${head_ref}. Base: ${prev_base}. Part of a PR decomposition; retarget to ${base} as parents merge."
    echo "# Group $((idx + 1)): ${branch}  (base: ${prev_base}, ${#paths[@]} path(s))"
    run git checkout -b "$branch" "$prev_base"
    run git checkout "$head_ref" -- "${paths[@]}"
    run git commit -m "$branch: carve $((idx + 1)) of ${#gnames[@]} from $head_ref"
    run git push -u origin "$branch"
    run "$GH_BIN" pr create --base "$prev_base" --head "$branch" --title "$title" --body "$body" ${gh_pr_args[@]+"${gh_pr_args[@]}"}
    echo ""
    prev_base="$branch"
done

if ! $execute; then
    echo "Nothing executed. Review the plan, then re-run with --execute (after user confirmation)."
    echo "As each PR merges, retarget the next: ${GH_BIN} pr edit <n> --base ${base}"
fi
