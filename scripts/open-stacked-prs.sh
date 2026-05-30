#!/usr/bin/env bash
set -euo pipefail

# open-stacked-prs.sh — materialize a PR-decomposition plan as a stack of
# branches and stacked GitHub PRs.
#
# OUTWARD-FACING: defaults to dry-run. It only prints the git/gh command plan
# unless --execute is given. The skill procedure must obtain explicit user
# confirmation and show the dry-run plan before passing --execute.

GH_BIN="${GH_BIN:-gh}"

command -v git >/dev/null || { echo "ERROR: git not found in PATH" >&2; exit 12; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repository" >&2; exit 11; }

base=""
head_ref="HEAD"
remote="origin"
remote_set=false
execute=false
allow_dirty=false
allow_protected=false
draft=false
from_json=false
gnames=()
gpaths=()

usage_error() {
    echo "ERROR: $1" >&2
    exit 10
}

require_value() {
    [ "$#" -ge 2 ] || usage_error "$1 needs a value"
}

add_group() {
    # Internally, gpaths is newline-separated to stay robust against paths
    # that contain commas (which --group-path exposes). Translate the
    # comma-separated --group form with pure-bash parameter expansion to
    # avoid a tr subshell on every call.
    local spec="$1" name rest
    case "$spec" in
        *:*) ;;
        *) usage_error "--group needs 'name:path1,path2,...'" ;;
    esac
    name="${spec%%:*}"
    rest="${spec#*:}"
    [ -n "$name" ] || usage_error "--group name is empty"
    [ -n "$rest" ] || usage_error "--group '$name' has no paths"
    gnames+=("$name")
    gpaths+=("${rest//,/$'\n'}")
}

add_group_path() {
    local name="$1" path="$2" i
    [ -n "$name" ] || usage_error "--group-path needs a non-empty NAME"
    [ -n "$path" ] || usage_error "--group-path '$name' needs a non-empty PATH"
    for ((i = 0; i < ${#gnames[@]}; i++)); do
        if [ "${gnames[$i]}" = "$name" ]; then
            gpaths[$i]+=$'\n'"$path"
            return
        fi
    done
    gnames+=("$name")
    gpaths+=("$path")
}

sanitize_branch_part() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._/-' '-' | sed -E 's#/{2,}#/#g; s#^-+##; s#-+$##'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --base) require_value "$@"; base="$2"; shift 2 ;;
        --head) require_value "$@"; head_ref="$2"; shift 2 ;;
        --remote) require_value "$@"; remote="$2"; remote_set=true; shift 2 ;;
        --group) require_value "$@"; add_group "$2"; shift 2 ;;
        --group-path)
            [ "$#" -ge 3 ] || usage_error "--group-path needs NAME PATH"
            add_group_path "$2" "$3"
            shift 3
            ;;
        --from-json) from_json=true; shift ;;
        --execute) execute=true; shift ;;
        --allow-dirty) allow_dirty=true; shift ;;
        --allow-protected) allow_protected=true; shift ;;
        --draft) draft=true; shift ;;
        --) shift; break ;;
        -*) usage_error "unknown flag: $1" ;;
        *) usage_error "unexpected arg: $1" ;;
    esac
done

if [ -z "$base" ]; then
    base="$(git symbolic-ref --quiet --short "refs/remotes/${remote}/HEAD" 2>/dev/null | sed "s#^${remote}/##" || true)"
    if [ -z "$base" ]; then
        for candidate in main master trunk; do
            if git show-ref --verify --quiet "refs/heads/$candidate"; then
                base="$candidate"
                break
            fi
        done
    fi
    [ -n "$base" ] || usage_error "cannot determine --base; pass it explicitly"
fi

if $from_json; then
    command -v python3 >/dev/null 2>&1 || usage_error "--from-json requires python3"
    # Capture stdout only and check exit so JSON parse failures surface as a
    # clear error instead of degrading into "no groups given". Let stderr flow
    # naturally to the terminal — folding it into stdout would corrupt
    # parsed_groups with python tracebacks that look like group definitions.
    parsed_groups="$(python3 -c '
import json, sys
d = json.load(sys.stdin)
for g in d.get("groups", []):
    paths = ",".join(f["path"] for f in g.get("files", []) if f.get("path"))
    if paths:
        print(g.get("id", "group") + "\t" + paths)
')" || {
        echo "ERROR: --from-json failed to parse stdin as JSON" >&2
        exit 19
    }
    while IFS=$'\t' read -r gid paths; do
        [ -n "$gid" ] || continue
        gnames+=("split/$(sanitize_branch_part "$gid")")
        gpaths+=("${paths//,/$'\n'}")
    done <<< "$parsed_groups"
fi

[ "${#gnames[@]}" -gt 0 ] || { echo "ERROR: no groups given (use --group or --from-json)" >&2; exit 15; }

branch_exists_locally() {
    git show-ref --verify --quiet "refs/heads/$1"
}

branch_exists_remotely() {
    git ls-remote --exit-code --heads "$remote" "$1" >/dev/null 2>&1
}

declare -A seen_branch_names=()
for branch in "${gnames[@]}"; do
    if [ -n "${seen_branch_names[$branch]:-}" ]; then
        echo "ERROR: duplicate target branch name: $branch" >&2
        exit 17
    fi
    seen_branch_names["$branch"]=1
done

if $execute; then
    $remote_set || usage_error "--execute requires explicit --remote <name>"
    git remote get-url "$remote" >/dev/null 2>&1 || usage_error "remote '$remote' does not exist"
    if ! $allow_dirty; then
        [ -z "$(git status --porcelain)" ] || { echo "ERROR: working tree is dirty; commit/stash or pass --allow-dirty" >&2; exit 13; }
    fi
    current_branch="$(git branch --show-current 2>/dev/null || true)"
    case "$current_branch" in
        main|master|trunk)
            $allow_protected || { echo "ERROR: refusing to execute from protected branch '$current_branch'; switch branches or pass --allow-protected" >&2; exit 16; } ;;
    esac
    command -v "$GH_BIN" >/dev/null 2>&1 || { echo "ERROR: '$GH_BIN' not found; install GitHub CLI or set GH_BIN" >&2; exit 14; }
    "$GH_BIN" auth status >/dev/null 2>&1 || { echo "ERROR: gh auth status failed; authenticate before executing" >&2; exit 14; }
    for branch in "${gnames[@]}"; do
        branch_exists_locally "$branch" && { echo "ERROR: local branch already exists: $branch" >&2; exit 17; }
        branch_exists_remotely "$branch" && { echo "ERROR: remote branch already exists on $remote: $branch" >&2; exit 18; }
    done
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
    echo "=== open-stacked-prs (dry-run; pass --execute after explicit user confirmation) ==="
    echo "Review this plan. Do not run it blindly."
fi
echo "Base: $base   Source: $head_ref   Remote: $remote   Groups: ${#gnames[@]}"
echo ""

prev_base="$base"
gh_pr_args=()
$draft && gh_pr_args+=(--draft)

for idx in "${!gnames[@]}"; do
    branch="${gnames[$idx]}"
    mapfile -t paths <<< "${gpaths[$idx]}"
    title="$branch"
    body="Stacked PR carved from ${head_ref}. Base: ${prev_base}. Part of a PR decomposition; retarget to ${base} as parents merge."
    echo "# Group $((idx + 1)): ${branch}  (base: ${prev_base}, ${#paths[@]} path(s))"
    run git switch -c "$branch" "$prev_base"
    run git restore --source="$head_ref" --staged --worktree -- "${paths[@]}"
    run git commit -m "$branch: carve $((idx + 1)) of ${#gnames[@]} from $head_ref"
    run git push -u "$remote" "$branch"
    run "$GH_BIN" pr create --base "$prev_base" --head "$branch" --title "$title" --body "$body" "${gh_pr_args[@]}"
    echo ""
    prev_base="$branch"
done

if ! $execute; then
    echo "Nothing executed. Re-run with --execute only after user confirmation."
    echo "As each PR merges, retarget the next: ${GH_BIN} pr edit <n> --base ${base}"
fi
