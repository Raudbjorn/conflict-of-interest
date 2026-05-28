#!/usr/bin/env bash
set -euo pipefail

command -v git >/dev/null || { echo "ERROR: git not found in PATH" >&2; exit 10; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repository" >&2; exit 11; }

base=""
other_ref=""
json=false
exclude_paths=(':!*.md' ':!*.txt' ':!*.rst' ':!docs/**' ':!references/**')

while [ "$#" -gt 0 ]; do
    case "$1" in
        --base) [ "$#" -ge 2 ] || { echo "ERROR: --base needs a ref" >&2; exit 10; }; base="$2"; shift 2 ;;
        --other) [ "$#" -ge 2 ] || { echo "ERROR: --other needs a ref" >&2; exit 10; }; other_ref="$2"; shift 2 ;;
        --exclude-paths) [ "$#" -ge 2 ] || { echo "ERROR: --exclude-paths needs a pattern" >&2; exit 10; }; exclude_paths+=(":!$2"); shift 2 ;;
        --json) json=true; shift ;;
        --) shift; break ;;
        -*) echo "ERROR: unknown flag: $1" >&2; exit 10 ;;
        *) echo "ERROR: unexpected arg: $1" >&2; exit 10 ;;
    esac
done

git_dir="$(git rev-parse --git-dir)"
if [ -z "$other_ref" ]; then
    if [ -f "$git_dir/MERGE_HEAD" ]; then other_ref=MERGE_HEAD
    elif [ -f "$git_dir/CHERRY_PICK_HEAD" ]; then other_ref=CHERRY_PICK_HEAD
    elif [ -f "$git_dir/REVERT_HEAD" ]; then other_ref=REVERT_HEAD
    elif [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then other_ref=REBASE_HEAD
    else
        echo "WARN: no active merge/rebase/cherry-pick/revert; nothing to audit" >&2
        exit 2
    fi
fi

if [ -z "$base" ]; then
    base="$(git merge-base HEAD "$other_ref" 2>/dev/null || true)"
    [ -n "$base" ] || { echo "ERROR: cannot determine merge base" >&2; exit 10; }
fi

language_globs=("*.py" "*.ts" "*.tsx" "*.js" "*.jsx" "*.mjs" "*.rs" "*.go" "*.java" "*.kt" "*.scala" "*.rb" "*.ex" "*.exs" "*.c" "*.cc" "*.cpp" "*.h" "*.hpp" "*.swift" "*.dart" "*.php")
symbol_regex='^[+-][[:space:]]*(def|class|fn |func |function |const |static |let |var |type |interface |struct |enum |trait |macro_rules!|export +(const|function|class)|public |private |protected )'
stop_words='^(def|class|fn|func|function|const|static|let|var|type|interface|struct|enum|trait|macro_rules|export|public|private|protected|async|pub|impl|from|import|use|require|include|return|if|else|for|while|in|of|as|with|self|this|None|True|False|null|undefined)$'

extract_symbols() {
    local ref="$1"
    git diff "$base...$ref" -- "${language_globs[@]}" 2>/dev/null \
        | grep -E "$symbol_regex" \
        | sed -E 's/^[+-][[:space:]]*//' \
        | grep -oE '[A-Za-z_][A-Za-z0-9_]+' \
        | awk "length(\$0) > 2 && \$0 !~ /$stop_words/ {print}" \
        | sort -u || true
}

our_symbols="$(extract_symbols HEAD)"
their_symbols="$(extract_symbols "$other_ref")"
suspects=()

check_suspect() {
    local sym="$1" modified_by="$2" opposite_ref opposite_label
    if [ "$modified_by" = ours ]; then
        opposite_ref="$other_ref"; opposite_label=theirs
    else
        opposite_ref=HEAD; opposite_label=ours
    fi
    if git diff "$base...$opposite_ref" -- "${language_globs[@]}" 2>/dev/null | grep -qE "\b${sym}\b"; then
        if git grep -qE "\b${sym}\b" -- "${exclude_paths[@]}" 2>/dev/null; then
            suspects+=("${sym}|${modified_by}|${opposite_label}")
        fi
    fi
}

while IFS= read -r sym; do
    [ -n "$sym" ] && check_suspect "$sym" ours
done <<< "$our_symbols"

while IFS= read -r sym; do
    [ -n "$sym" ] || continue
    printf '%s\n' "${suspects[@]+"${suspects[@]}"}" | grep -q "^${sym}|" && continue
    check_suspect "$sym" theirs
done <<< "$their_symbols"

if $json; then
    printf '{"base":"%s","other_ref":"%s","suspects":[' "$base" "$other_ref"
    for i in "${!suspects[@]}"; do
        IFS='|' read -r sym modified_by referenced_by <<< "${suspects[$i]}"
        [ "$i" -gt 0 ] && printf ','
        printf '{"symbol":"%s","modified_by":"%s","referenced_by":"%s"}' "$sym" "$modified_by" "$referenced_by"
    done
    printf ']}\n'
else
    echo "=== semantic-audit ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ==="
    echo "Base: $base"
    echo "Other: $other_ref"
    echo ""
    if [ "${#suspects[@]}" -eq 0 ]; then
        echo "No semantic-conflict suspects found."
    else
        echo "Found ${#suspects[@]} semantic-conflict suspect(s):"
        for entry in "${suspects[@]}"; do
            IFS='|' read -r sym modified_by referenced_by <<< "$entry"
            echo "SUSPECT: $sym modified by $modified_by, referenced by $referenced_by"
        done
    fi
fi

[ "${#suspects[@]}" -eq 0 ] || exit 1

