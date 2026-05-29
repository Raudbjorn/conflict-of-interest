#!/usr/bin/env bash
set -euo pipefail

# suggest-pr-split.sh — propose how to decompose a large change set or conflict
# into smaller PRs along functional (module) and structural (layer) boundaries.
# Read-only analysis; never creates branches or PRs. See open-stacked-prs.sh for
# materializing a proposal and references/pr-decomposition.md for the theory.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/path-classifiers.sh
source "$SCRIPT_DIR/lib/path-classifiers.sh"

classify_layer() {
    local path="$1"
    if is_lockfile "$path"; then echo lockfile
    elif is_migration "$path"; then echo migration
    elif is_generated "$path"; then echo generated
    elif is_test_path "$path"; then echo test
    elif is_ui_path "$path"; then echo ui
    elif is_config_path "$path"; then echo config
    elif is_doc_path "$path"; then echo docs
    else echo source
    fi
}

layer_order() {
    case "$1" in
        refactor) echo 0 ;;
        lockfile|migration) echo 10 ;;
        generated) echo 20 ;;
        source) echo 30 ;;
        config) echo 40 ;;
        ui) echo 50 ;;
        test) echo 60 ;;
        docs) echo 70 ;;
        *) echo 90 ;;
    esac
}

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
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

layer_count() {
    printf '%s' "$1" | tr ' ' '\n' | sed '/^$/d' | sort -u | grep -c . || true
}

usage_error() {
    echo "ERROR: $1" >&2
    exit 10
}

require_value() {
    [ "$#" -ge 2 ] || usage_error "$1 needs a value"
}

main() {
    command -v git >/dev/null || { echo "ERROR: git not found in PATH" >&2; exit 12; }
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repository" >&2; exit 11; }

    local conflicts_mode=false base="" head="" json=false no_color=false
    local rename_threshold=90 large_loc=400 scope="unmerged"
    local exclude=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --conflicts) conflicts_mode=true; shift ;;
            --scope) require_value "$@"; scope="$2"; shift 2 ;;
            --base) require_value "$@"; base="$2"; shift 2 ;;
            --head) require_value "$@"; head="$2"; shift 2 ;;
            --rename-threshold) require_value "$@"; rename_threshold="$2"; shift 2 ;;
            --large-loc|--max-group-loc) require_value "$@"; large_loc="$2"; shift 2 ;;
            --exclude-paths) require_value "$@"; exclude+=(":!$2"); shift 2 ;;
            --json) json=true; shift ;;
            --no-color) no_color=true; shift ;;
            --) shift; break ;;
            -*) usage_error "unknown flag: $1" ;;
            *) usage_error "unexpected arg: $1" ;;
        esac
    done

    case "$rename_threshold" in ''|*[!0-9]*) usage_error "--rename-threshold must be an integer" ;; esac
    case "$large_loc" in ''|*[!0-9]*) usage_error "--large-loc must be an integer" ;; esac
    case "$scope" in unmerged|incoming-range|both) ;; *) usage_error "--scope must be unmerged, incoming-range, or both" ;; esac
    $no_color || true

    local git_dir mode other_ref="" range="" head_report="" scope_report=""
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
            [ -n "$base" ] || usage_error "cannot determine merge base; pass --base"
        fi
        if ! git merge-base --is-ancestor "$base" "$head" 2>/dev/null; then
            echo "WARN: base '$base' is not an ancestor of head '$head'; using symmetric diff only" >&2
        fi
        range="$base...$head"
        head_report="$head"
        scope_report="null"
    else
        if [ -f "$git_dir/MERGE_HEAD" ]; then other_ref=MERGE_HEAD
        elif [ -f "$git_dir/CHERRY_PICK_HEAD" ]; then other_ref=CHERRY_PICK_HEAD
        elif [ -f "$git_dir/REVERT_HEAD" ]; then other_ref=REVERT_HEAD
        elif [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then other_ref=REBASE_HEAD
        fi
        base="$(git merge-base HEAD "${other_ref:-HEAD}" 2>/dev/null || true)"
        head_report="${other_ref:-WORKING}"
        scope_report="$scope"
        if [ "$scope" != "unmerged" ]; then
            [ -n "$other_ref" ] || usage_error "--scope $scope requires an active operation ref"
            [ -n "$base" ] || usage_error "cannot determine merge base for active operation"
            range="$base...$other_ref"
        fi
    fi

    file_loc() {
        local p="$1" ns added deleted
        ns="$(git -c core.quotePath=false diff --numstat ${range:+"$range"} -- "$p" 2>/dev/null | head -n1 || true)"
        added="$(printf '%s' "$ns" | cut -f1)"
        deleted="$(printf '%s' "$ns" | cut -f2)"
        [ "$added" = "-" ] && added=0
        [ "$deleted" = "-" ] && deleted=0
        [ -n "$added" ] || added=0
        [ -n "$deleted" ] || deleted=0
        echo $((added + deleted))
    }

    collect_range_records() {
        local status path from
        git -c core.quotePath=false diff -M1% --name-status -z "$range" -- "${exclude[@]}" 2>/dev/null |
            while IFS= read -r -d '' status; do
                [ -n "$status" ] || continue
                case "$status" in
                    R*|C*)
                        IFS= read -r -d '' from || true
                        IFS= read -r -d '' path || true
                        printf '%s\t%s\t%s\n' "$path" "$status" "$from"
                        ;;
                    *)
                        IFS= read -r -d '' path || true
                        printf '%s\t%s\t\n' "$path" "$status"
                        ;;
                esac
            done
    }

    collect_unmerged_records() {
        local path
        git -c core.quotePath=false diff --name-only --diff-filter=U -- "${exclude[@]}" 2>/dev/null |
            while IFS= read -r path; do
                [ -n "$path" ] || continue
                printf '%s\tU\t\n' "$path"
            done
    }

    local records=()
    if [ "$mode" = range ]; then
        mapfile -t records < <(collect_range_records)
    else
        case "$scope" in
            unmerged)
                mapfile -t records < <(collect_unmerged_records)
                ;;
            incoming-range)
                mapfile -t records < <(collect_range_records)
                ;;
            both)
                mapfile -t records < <({ collect_range_records; collect_unmerged_records; } | awk -F '\t' '!seen[$1]++')
                ;;
        esac
    fi

    if [ "${#records[@]}" -eq 0 ]; then
        if $json; then
            printf '{"mode":"%s","scope":%s,"base":"%s","head":"%s","thresholds":{"rename":%d,"large_loc":%d},"groups":[],"warnings":[]}\n' \
                "$mode" "$([ "$scope_report" = null ] && echo null || printf '"%s"' "$scope_report")" \
                "$(json_escape "$base")" "$(json_escape "$head_report")" "$rename_threshold" "$large_loc"
        else
            echo "No changes to split."
        fi
        exit 1
    fi

    declare -A g_files=() g_loc=() g_layers=() g_minorder=() g_minlayer=() g_weak=() g_warn=() seen_refactor_modules=() seen_behavior_modules=()
    local rec path status from gid layer weak score d ord loc module
    for rec in "${records[@]}"; do
        IFS=$'\t' read -r path status from <<< "$rec"
        [ -n "${path:-}" ] || continue
        weak=0
        module="$(top_module "$path")"
        if [[ "$status" == R* ]]; then
            d="${status#R}"; [ -n "$d" ] || d=100
            score=$((10#$d))
            if [ "$score" -ge "$rename_threshold" ]; then
                gid="refactor-baseline"; layer="refactor"; seen_refactor_modules["$module"]=1
            else
                gid="$module"; layer="$(classify_layer "$path")"; weak=1
                g_warn["$gid"]+="sub-threshold rename ${status} for ${path}; "
            fi
        else
            gid="$module"; layer="$(classify_layer "$path")"; seen_behavior_modules["$module"]=1
        fi
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

    for module in "${!seen_refactor_modules[@]}"; do
        if [ -n "${seen_behavior_modules[$module]:-}" ]; then
            g_weak["refactor-baseline"]=1
            g_warn["refactor-baseline"]+="refactor touches module '${module}' that also has behavior changes; "
        fi
    done

    group_confidence() {
        local gid="$1" lc
        [ -n "${g_weak[$gid]:-}" ] && { echo low; return; }
        [ "$gid" = "refactor-baseline" ] && { echo high; return; }
        lc="$(layer_count "${g_layers[$gid]}")"
        if [ "$lc" -ge 3 ]; then echo low
        elif [ "$lc" -eq 2 ]; then echo medium
        else echo high
        fi
    }

    local sorted
    sorted="$(for gid in "${!g_files[@]}"; do printf '%s\t%s\n' "${g_minorder[$gid]}" "$gid"; done | sort -t$'\t' -k1,1n -k2,2)"

    local warnings=() conf over gid
    while IFS=$'\t' read -r _ gid; do
        [ -n "${gid:-}" ] || continue
        conf="$(group_confidence "$gid")"
        if [ "$conf" = low ]; then
            warnings+=("group '${gid}' is low confidence: verify dependencies before splitting")
        fi
        if [ -z "${g_weak[$gid]:-}" ] && [ "$(layer_count "${g_layers[$gid]}")" -ge 3 ]; then
            warnings+=("group '${gid}' is cross-cutting across 3+ layers; prefer a manual dependency check")
        fi
        if [ "${g_loc[$gid]:-0}" -gt "$large_loc" ]; then
            warnings+=("group '${gid}' exceeds ${large_loc} LOC: overlap risk elevated")
        fi
    done <<< "$sorted"
    if [ "$scope" = both ] && [ "$mode" = conflicts ]; then
        warnings+=("scope 'both' combines incoming range analysis with currently unmerged files")
    fi

    if $json; then
        local scope_json
        if [ "$scope_report" = null ]; then scope_json=null; else scope_json="\"$(json_escape "$scope_report")\""; fi
        printf '{"mode":"%s","scope":%s,"base":"%s","head":"%s","thresholds":{"rename":%d,"large_loc":%d},"groups":[' \
            "$mode" "$scope_json" "$(json_escape "$base")" "$(json_escape "$head_report")" "$rename_threshold" "$large_loc"
        local gfirst=1 fpath fstatus ffrom flayer ffirst w
        while IFS=$'\t' read -r _ gid; do
            [ -n "${gid:-}" ] || continue
            [ "$gfirst" -eq 1 ] || printf ','
            gfirst=0
            conf="$(group_confidence "$gid")"
            over=false; [ "${g_loc[$gid]:-0}" -gt "$large_loc" ] && over=true
            printf '{"id":"%s","order":%d,"module":"%s","layer":"%s","confidence":"%s","loc":%d,"over_large_loc":%s,"warnings":[' \
                "$(json_escape "$gid")" "${g_minorder[$gid]}" "$(json_escape "$gid")" "${g_minlayer[$gid]}" "$conf" "${g_loc[$gid]:-0}" "$over"
            ffirst=1
            if [ -n "${g_warn[$gid]:-}" ]; then
                w="${g_warn[$gid]}"
                w="${w%; }"
                printf '"%s"' "$(json_escape "$w")"
                ffirst=0
            fi
            printf '],"files":['
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
        echo "=== suggest-pr-split (${mode}${range:+ $range}${scope_report:+ scope=$scope_report}) ==="
        local ngroups; ngroups="$(printf '%s\n' "$sorted" | sed '/^$/d' | wc -l | tr -d ' ')"
        printf 'Proposed groups: %s   Rename threshold: %s%%   Large-LOC: %s\n\n' "$ngroups" "$rename_threshold" "$large_loc"
        printf '%-5s %-22s %-10s %-6s %-7s %-7s %s\n' Order Group Layer Files LOC Conf Flag
        local nfiles flag
        while IFS=$'\t' read -r _ gid; do
            [ -n "${gid:-}" ] || continue
            conf="$(group_confidence "$gid")"
            nfiles="$(printf '%s' "${g_files[$gid]}" | sed '/^$/d' | wc -l | tr -d ' ')"
            flag=""
            [ "$conf" = low ] && flag="LOW-CONFIDENCE"
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
