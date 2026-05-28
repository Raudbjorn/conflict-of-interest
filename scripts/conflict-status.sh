#!/usr/bin/env bash
set -euo pipefail

command -v git >/dev/null || { echo "ERROR: git not found in PATH" >&2; exit 12; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repository" >&2; exit 11; }

git_dir="$(git rev-parse --git-dir)"

read_first_existing() {
    local file
    for file in "$@"; do
        if [ -f "$file" ]; then
            head -n 1 "$file"
            return 0
        fi
    done
    return 1
}

strip_ref_prefix() {
    local name="$1"
    printf '%s' "${name#refs/heads/}"
}

current_branch() {
    git branch --show-current 2>/dev/null || true
}

rebase_status() {
    local dir="$1" current="" total="" progress="" branch=""
    current="$(read_first_existing "$dir/msgnum" "$dir/next" 2>/dev/null || true)"
    total="$(read_first_existing "$dir/end" "$dir/last" 2>/dev/null || true)"
    if [ -n "$current" ] && [ -n "$total" ]; then
        progress="${current}/${total}"
    fi
    branch="$(read_first_existing "$dir/head-name" 2>/dev/null || true)"
    branch="$(strip_ref_prefix "${branch:-$(current_branch)}")"
    printf 'rebase\t%s\t%s' "$progress" "$branch"
}

unmerged_count() {
    git diff --name-only --diff-filter=U 2>/dev/null | awk 'NF {count++} END {print count + 0}'
}

if [ -d "$git_dir/rebase-merge" ]; then
    printf '%s\t%s\n' "$(rebase_status "$git_dir/rebase-merge")" "$(unmerged_count)"
elif [ -d "$git_dir/rebase-apply" ]; then
    printf '%s\t%s\n' "$(rebase_status "$git_dir/rebase-apply")" "$(unmerged_count)"
elif [ -f "$git_dir/MERGE_HEAD" ]; then
    printf 'merge\t\t%s\t%s\n' "$(current_branch)" "$(unmerged_count)"
elif [ -f "$git_dir/CHERRY_PICK_HEAD" ]; then
    printf 'cherry-pick\t\t%s\t%s\n' "$(current_branch)" "$(unmerged_count)"
elif [ -f "$git_dir/REVERT_HEAD" ]; then
    printf 'revert\t\t%s\t%s\n' "$(current_branch)" "$(unmerged_count)"
else
    printf 'none\t\t%s\t%s\n' "$(current_branch)" "$(unmerged_count)"
fi

