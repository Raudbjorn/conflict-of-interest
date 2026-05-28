#!/usr/bin/env bash
set -euo pipefail

# suggest-pr-split.sh — propose how to decompose a large change set or conflict
# into smaller PRs along functional (module) and structural (layer) boundaries.
# Read-only analysis; never creates branches or PRs. See open-stacked-prs.sh for
# materializing a proposal and references/pr-decomposition.md for the theory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Reuse the categorizer's path predicates (is_lockfile/is_migration/is_generated).
# categorize-conflicts.sh guards its main() with a BASH_SOURCE check, so sourcing
# only imports functions.
# shellcheck source=categorize-conflicts.sh
source "$SCRIPT_DIR/categorize-conflicts.sh"

# --- layer predicates (pure, path-only) -----------------------------------

is_test_path() {
    local lower
    lower="$(lower_path "$1")"
    case "$lower" in
        tests/*|*/tests/*|test/*|*/test/*|spec/*|*/spec/*|*/__tests__/*) return 0 ;;
        *_test.*|*.test.*|*.spec.*|*_spec.rb|*_test.go) return 0 ;;
        *) return 1 ;;
    esac
}

is_config_path() {
    local lower name
    lower="$(lower_path "$1")"
    name="${1##*/}"
    case "$lower" in
        *.json|*.yml|*.yaml|*.toml|*.ini|*.cfg|*.conf|*.properties|*.env|*.config.js|*.config.ts|*.config.mjs) return 0 ;;
    esac
    case "$name" in
        .env*|Dockerfile|.dockerignore|.gitignore|.editorconfig) return 0 ;;
    esac
    return 1
}

is_ui_asset() {
    local lower
    lower="$(lower_path "$1")"
    case "$lower" in
        *.css|*.scss|*.sass|*.less|*.svg|*.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.html|*.vue|*.svelte) return 0 ;;
    esac
    case "$lower" in
        */components/*|*/views/*|*/pages/*|*/ui/*)
            case "$lower" in
                *.ts|*.tsx|*.js|*.jsx|*.mjs) return 0 ;;
            esac ;;
    esac
    return 1
}

classify_layer() {
    local path="$1"
    if is_lockfile "$path"; then echo lockfile
    elif is_migration "$path"; then echo migration
    elif is_generated "$path"; then echo generated
    elif is_test_path "$path"; then echo test
    elif is_ui_asset "$path"; then echo ui
    elif is_config_path "$path"; then echo config
    else echo source
    fi
}

# Merge-order tier: refactor first, then schema/locks, then code, then ui/tests.
layer_order() {
    case "$1" in
        refactor) echo 0 ;;
        lockfile) echo 1 ;;
        migration) echo 1 ;;
        generated) echo 2 ;;
        source) echo 3 ;;
        config) echo 4 ;;
        ui) echo 5 ;;
        test) echo 6 ;;
        *) echo 9 ;;
    esac
}

# Cluster key: top-level directory, or two segments under a monorepo container.
top_module() {
    local path="$1" first rest second
    case "$path" in
        */*) ;;
        *) echo "(root)"; return ;;
    esac
    first="${path%%/*}"
    rest="${path#*/}"
    case "$first" in
        src|packages|apps|lib|libs|internal|cmd|modules|services|pkg)
            case "$rest" in
                */*) second="${rest%%/*}"; echo "$first/$second" ;;
                *) echo "$first" ;;
            esac ;;
        *) echo "$first" ;;
    esac
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

layer_count() {
    printf '%s' "$1" | tr ' ' '\n' | sed '/^$/d' | sort -u | grep -c . || true
}

main() {
    command -v git >/dev/null || { echo "ERROR: git not found in PATH" >&2; exit 12; }
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repository" >&2; exit 11; }

    local conflicts_mode=false base="" head="" json=false
    local rename_threshold=90 large_loc=400
    local exclude=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --conflicts) conflicts_mode=true; shift ;;
            --base) [ "$#" -ge 2 ] || { echo "ERROR: --base needs a ref" >&2; exit 10; }; base="$2"; shift 2 ;;
            --head) [ "$#" -ge 2 ] || { echo "ERROR: --head needs a ref" >&2; exit 10; }; head="$2"; shift 2 ;;
            --rename-threshold) [ "$#" -ge 2 ] || { echo "ERROR: --rename-threshold needs a number" >&2; exit 10; }; rename_threshold="$2"; shift 2 ;;
            --large-loc) [ "$#" -ge 2 ] || { echo "ERROR: --large-loc needs a number" >&2; exit 10; }; large_loc="$2"; shift 2 ;;
            --exclude-paths) [ "$#" -ge 2 ] || { echo "ERROR: --exclude-paths needs a pattern" >&2; exit 10; }; exclude+=(":!$2"); shift 2 ;;
            --json) json=true; shift ;;
            --) shift; break ;;
            -*) echo "ERROR: unknown flag: $1" >&2; exit 10 ;;
            *) echo "ERROR: unexpected arg: $1" >&2; exit 10 ;;
        esac
    done

    case "$rename_threshold" in ''|*[!0-9]*) echo "ERROR: --rename-threshold must be an integer" >&2; exit 10 ;; esac
    case "$large_loc" in ''|*[!0-9]*) echo "ERROR: --large-loc must be an integer" >&2; exit 10 ;; esac

    local git_dir mode other_ref="" range="" head_report=""
    git_dir="$(git rev-parse --git-dir)"

    if $conflicts_mode; then
        mode=conflicts
    elif [ -n "$base" ] || [ -n "$head" ]; then
        mode=range
    elif [ -f "$git_dir/MERGE_HEAD" ] || [ -f "$git_dir/CHERRY_PICK_HEAD" ] || \
         [ -f "$git_dir/REVERT_HEAD" ] || [ -d "$git_dir/rebase-merge" ] || \
         [ -d "$git_dir/rebase-apply" ]; then
        mode=conflicts
    else
        echo "WARN: no active operation and no --base/--head; nothing to split" >&2
        exit 2
    fi

    if [ "$mode" = range ]; then
        head="${head:-HEAD}"
        if [ -z "$base" ]; then
            base="$(git merge-base HEAD "$head" 2>/dev/null || true)"
            [ -n "$base" ] || { echo "ERROR: cannot determine merge base; pass --base" >&2; exit 10; }
        fi
        range="$base...$head"
        head_report="$head"
    else
        if [ -f "$git_dir/MERGE_HEAD" ]; then other_ref=MERGE_HEAD
        elif [ -f "$git_dir/CHERRY_PICK_HEAD" ]; then other_ref=CHERRY_PICK_HEAD
        elif [ -f "$git_dir/REVERT_HEAD" ]; then other_ref=REVERT_HEAD
        elif [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then other_ref=REBASE_HEAD
        fi
        base="$(git merge-base HEAD "${other_ref:-HEAD}" 2>/dev/null || true)"
        range=""
        head_report="${other_ref:-WORKING}"
    fi

    file_loc() {
        local p="$1" ns added deleted
        ns="$(git diff --numstat $range -- "$p" 2>/dev/null | head -n1 || true)"
        added="$(printf '%s' "$ns" | cut -f1)"
        deleted="$(printf '%s' "$ns" | cut -f2)"
        [ "$added" = "-" ] && added=0
        [ "$deleted" = "-" ] && deleted=0
        [ -n "$added" ] || added=0
        [ -n "$deleted" ] || deleted=0
        echo $((added + deleted))
    }

    # --- collect file records: path<TAB>status<TAB>from -----------------
    local records=()
    if [ "$mode" = range ]; then
        local c1 c2 c3
        while IFS=$'\t' read -r c1 c2 c3; do
            [ -n "${c1:-}" ] || continue
            case "$c1" in
                R*|C*) records+=("${c3}"$'\t'"${c1}"$'\t'"${c2}") ;;
                *)     records+=("${c2}"$'\t'"${c1}"$'\t') ;;
            esac
        done < <(git diff -M --name-status "$range" -- ${exclude[@]+"${exclude[@]}"} 2>/dev/null || true)
    else
        local p
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            records+=("${p}"$'\t'"U"$'\t')
        done < <(git diff --name-only --diff-filter=U -- ${exclude[@]+"${exclude[@]}"} 2>/dev/null || true)
    fi

    if [ "${#records[@]}" -eq 0 ]; then
        if $json; then echo '{"groups":[]}'; else echo "No changes to split."; fi
        exit 1
    fi

    # --- group by module (renames >= threshold go to refactor-baseline) -
    declare -A g_files=() g_loc=() g_layers=() g_minorder=() g_minlayer=() g_weak=()
    local rec path status from gid layer weak score d ord loc
    for rec in "${records[@]}"; do
        IFS=$'\t' read -r path status from <<< "$rec"
        weak=0
        if [[ "$status" == R* ]]; then
            d="${status#R}"; [ -n "$d" ] || d=100
            score=$((10#$d))
            if [ "$score" -ge "$rename_threshold" ]; then
                gid="refactor-baseline"; layer="refactor"
            else
                gid="$(top_module "$path")"; layer="$(classify_layer "$path")"; weak=1
            fi
        else
            gid="$(top_module "$path")"; layer="$(classify_layer "$path")"
        fi
        # 'from' is optional, so keep it last: read collapses empty middle
        # fields when IFS is a whitespace char (tab).
        g_files["$gid"]+="${path}"$'\t'"${status}"$'\t'"${layer}"$'\t'"${from}"$'\n'
        loc="$(file_loc "$path")"
        g_loc["$gid"]=$(( ${g_loc["$gid"]:-0} + loc ))
        g_layers["$gid"]+="${layer} "
        [ "$weak" -eq 1 ] && g_weak["$gid"]=1
        ord="$(layer_order "$layer")"
        if [ -z "${g_minorder["$gid"]:-}" ] || [ "$ord" -lt "${g_minorder["$gid"]}" ]; then
            g_minorder["$gid"]="$ord"; g_minlayer["$gid"]="$layer"
        fi
    done

    group_confidence() {
        local gid="$1" lc
        [ "$gid" = "refactor-baseline" ] && { echo high; return; }
        [ -n "${g_weak[$gid]:-}" ] && { echo low; return; }
        lc="$(layer_count "${g_layers[$gid]}")"
        if [ "$lc" -ge 3 ]; then echo low
        elif [ "$lc" -eq 2 ]; then echo medium
        else echo high
        fi
    }

    # --- sort group ids by (order, id) ----------------------------------
    local sorted gid_line
    sorted="$(for gid in "${!g_files[@]}"; do printf '%s\t%s\n' "${g_minorder[$gid]}" "$gid"; done | sort -t$'\t' -k1,1n -k2,2)"

    # --- warnings -------------------------------------------------------
    local warnings=() conf over
    while IFS=$'\t' read -r _ gid; do
        [ -n "${gid:-}" ] || continue
        conf="$(group_confidence "$gid")"
        if [ "$conf" = low ]; then
            warnings+=("group '${gid}' is cross-cutting (multi-layer or weak rename): boundary is structural only; verify dependencies before splitting")
        fi
        if [ "${g_loc[$gid]:-0}" -gt "$large_loc" ]; then
            warnings+=("group '${gid}' exceeds ${large_loc} LOC: overlap risk elevated")
        fi
    done <<< "$sorted"

    # --- emit -----------------------------------------------------------
    if $json; then
        printf '{"mode":"%s","base":"%s","head":"%s","thresholds":{"rename":%d,"large_loc":%d},"groups":[' \
            "$mode" "$(json_escape "$base")" "$(json_escape "$head_report")" "$rename_threshold" "$large_loc"
        local gfirst=1 fline fpath fstatus ffrom flayer ffirst
        while IFS=$'\t' read -r _ gid; do
            [ -n "${gid:-}" ] || continue
            [ "$gfirst" -eq 1 ] || printf ','
            gfirst=0
            conf="$(group_confidence "$gid")"
            over=false; [ "${g_loc[$gid]:-0}" -gt "$large_loc" ] && over=true
            printf '{"id":"%s","order":%d,"layer":"%s","confidence":"%s","loc":%d,"over_large_loc":%s,"files":[' \
                "$(json_escape "$gid")" "${g_minorder[$gid]}" "${g_minlayer[$gid]}" "$conf" "${g_loc[$gid]:-0}" "$over"
            ffirst=1
            while IFS=$'\t' read -r fpath fstatus flayer ffrom; do
                [ -n "${fpath:-}" ] || continue
                [ "$ffirst" -eq 1 ] || printf ','
                ffirst=0
                printf '{"path":"%s","status":"%s","layer":"%s"' \
                    "$(json_escape "$fpath")" "$(json_escape "$fstatus")" "$flayer"
                [ -n "${ffrom:-}" ] && printf ',"from":"%s"' "$(json_escape "$ffrom")"
                printf '}'
            done <<< "${g_files[$gid]}"
            printf ']}'
        done <<< "$sorted"
        printf '],"warnings":['
        local wfirst=1 i
        for ((i=0; i<${#warnings[@]}; i++)); do
            [ "$wfirst" -eq 1 ] || printf ','
            wfirst=0
            printf '"%s"' "$(json_escape "${warnings[$i]}")"
        done
        printf ']}\n'
    else
        echo "=== suggest-pr-split (${mode}${range:+ $range}) ==="
        local ngroups; ngroups="$(printf '%s\n' "$sorted" | sed '/^$/d' | wc -l | tr -d ' ')"
        printf 'Proposed groups: %s   Rename threshold: %s%%   Large-LOC: %s\n\n' "$ngroups" "$rename_threshold" "$large_loc"
        printf '%-5s %-22s %-10s %-6s %-7s %-7s %s\n' Order Group Layer Files LOC Conf Flag
        local nfiles flag
        while IFS=$'\t' read -r _ gid; do
            [ -n "${gid:-}" ] || continue
            conf="$(group_confidence "$gid")"
            nfiles="$(printf '%s' "${g_files[$gid]}" | sed '/^$/d' | wc -l | tr -d ' ')"
            flag=""
            [ "$conf" = low ] && flag="CROSS-CUTTING"
            [ "${g_loc[$gid]:-0}" -gt "$large_loc" ] && flag="${flag:+$flag }>LOC"
            printf '%-5s %-22s %-10s %-6s %-7s %-7s %s\n' \
                "${g_minorder[$gid]}" "$gid" "${g_minlayer[$gid]}" "$nfiles" "${g_loc[$gid]:-0}" "$conf" "$flag"
        done <<< "$sorted"
        if [ "${#warnings[@]}" -gt 0 ]; then
            echo ""
            local wi
            for ((wi=0; wi<${#warnings[@]}; wi++)); do
                echo "WARN: ${warnings[$wi]}"
            done
            echo ""
            echo "See references/pr-decomposition.md for boundary heuristics and git surgery."
        fi
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
