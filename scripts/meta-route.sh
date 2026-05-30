#!/usr/bin/env bash
set -euo pipefail

# meta-route.sh — per-file deterministic router for the "other" category in
# SKILL.md Step 3i. Collects signals from existing helpers (categorize-conflicts,
# balance-of-blocks, detect-stacked-pr, optional historical-resolution-search)
# and emits a JSON or TSV routing record per file. Augments (does NOT replace)
# the prose Step 3i.1-9; rows are advisory, never actuating.
#
# Every row in the routing table cites an H-NN heuristic; see
# references/meta-resolver.md and docs/research-synthesis.md.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Sum lines on each side across all conflict blocks in a file plus a 0/1 flag
# for whether any block carried a diff3 base section. Prints "left base right has_base".
parse_balance() {
    local file="$1" line in_block=0 section="" left=0 base=0 right=0 has_base=0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '<<<<<<< '*) in_block=1; section=left ;;
            '||||||| '*) [ "$in_block" -eq 1 ] && { section=base; has_base=1; } ;;
            '=======')   [ "$in_block" -eq 1 ] && section=right ;;
            '>>>>>>> '*) [ "$in_block" -eq 1 ] && in_block=0 ;;
            *)
                if [ "$in_block" -eq 1 ]; then
                    case "$section" in
                        left)  left=$((left + 1)) ;;
                        base)  base=$((base + 1)) ;;
                        right) right=$((right + 1)) ;;
                    esac
                fi ;;
        esac
    done < "$file"
    printf '%s %s %s %s\n' "$left" "$base" "$right" "$has_base"
}

# Aggregate detect-stacked-pr.sh's per-block JSON: prints
#   "<num_blocks> <all_auto_head_flag> <has_ask_flag> <min_similarity_or_null>"
aggregate_stacked() {
    local out="$1"
    local verdicts pcts num all_ah has_ask min_pct
    verdicts="$(printf '%s' "$out" | grep -oE '"verdict":"[A-Z_]+"' | sed -E 's/.*"verdict":"([^"]+)"/\1/' || true)"
    pcts="$(printf '%s' "$out" | grep -oE '"similarity":[0-9]+' | sed -E 's/.*:([0-9]+)/\1/' || true)"
    num="$(printf '%s\n' "$verdicts" | awk 'NF {n++} END {print n + 0}')"
    if [ "$num" -eq 0 ]; then
        printf '0 0 0 null\n'; return
    fi
    all_ah=1; has_ask=0
    local v
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        case "$v" in
            AUTO_HEAD) ;;
            ASK) has_ask=1; all_ah=0 ;;
            *) all_ah=0 ;;
        esac
    done <<< "$verdicts"
    if [ -n "$pcts" ]; then
        min_pct="$(printf '%s\n' "$pcts" | awk 'NF' | sort -n | head -n1)"
    else
        min_pct=null
    fi
    printf '%s %s %s %s\n' "$num" "$all_ah" "$has_ask" "$min_pct"
}

main() {
    command -v git >/dev/null || { echo "ERROR: git not found in PATH" >&2; exit 12; }
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repository" >&2; exit 11; }

    local files=() use_unmerged=false history_search=false json=false
    local imbalance_threshold=3 large_threshold=300
    local ask_stacked=70 auto_stacked=95 history_threshold=50

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --file) [ "$#" -ge 2 ] || { echo "ERROR: --file needs a path" >&2; exit 10; }; files+=("$2"); shift 2 ;;
            --unmerged-only) use_unmerged=true; shift ;;
            --history-search) history_search=true; shift ;;
            --imbalance-threshold) [ "$#" -ge 2 ] || { echo "ERROR: --imbalance-threshold needs a number" >&2; exit 10; }; imbalance_threshold="$2"; shift 2 ;;
            --large-threshold) [ "$#" -ge 2 ] || { echo "ERROR: --large-threshold needs a number" >&2; exit 10; }; large_threshold="$2"; shift 2 ;;
            --ask-stacked) [ "$#" -ge 2 ] || { echo "ERROR: --ask-stacked needs a number" >&2; exit 10; }; ask_stacked="$2"; shift 2 ;;
            --auto-stacked) [ "$#" -ge 2 ] || { echo "ERROR: --auto-stacked needs a number" >&2; exit 10; }; auto_stacked="$2"; shift 2 ;;
            --history-threshold) [ "$#" -ge 2 ] || { echo "ERROR: --history-threshold needs a number" >&2; exit 10; }; history_threshold="$2"; shift 2 ;;
            --json) json=true; shift ;;
            --tsv) json=false; shift ;;
            --) shift; break ;;
            -*) echo "ERROR: unknown flag: $1" >&2; exit 10 ;;
            *) echo "ERROR: unexpected arg: $1" >&2; exit 10 ;;
        esac
    done
    for v in imbalance_threshold large_threshold ask_stacked auto_stacked history_threshold; do
        case "${!v}" in ''|*[!0-9]*) echo "ERROR: --${v//_/-} must be an integer" >&2; exit 10 ;; esac
    done

    if ! $use_unmerged && [ "${#files[@]}" -eq 0 ]; then
        use_unmerged=true
    fi

    # Build category map from a single categorize-conflicts.sh call.
    local cat_output
    if ! cat_output="$("$SCRIPT_DIR/categorize-conflicts.sh" 2>/dev/null)"; then
        echo "ERROR: categorize-conflicts.sh failed" >&2; exit 12
    fi
    declare -A category=()
    while IFS=$'\t' read -r c p; do
        [ -n "${c:-}" ] || continue
        category["$p"]="$c"
    done <<< "$cat_output"

    # Determine file list.
    local effective_files=()
    if $use_unmerged; then
        local p
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            effective_files+=("$p")
        done < <(git diff --name-only --diff-filter=U 2>/dev/null || true)
    else
        effective_files=("${files[@]}")
    fi

    if [ "${#effective_files[@]}" -eq 0 ]; then
        if $json; then echo "[]"; else :; fi
        exit 2
    fi

    # Emit per file.
    local first=1
    $json && printf '['
    for f in "${effective_files[@]}"; do
        local cat="${category[$f]:-other}"
        local route="halt-other" reason="unmatched" conf="none"
        local imbalance_ratio=null total_lines=0 empty_side=null has_base_field=null
        local stacked_verdict=null stacked_pct=null history_top_score=null

        if [ "$cat" != "other" ]; then
            route="mechanical"; reason="category=$cat"; conf="high"
        else
            if [ ! -r "$f" ]; then
                route="halt-other"; reason="subcall_failed=worktree_unreadable"; conf="none"
            else
                # Balance signals.
                local left base right has_base
                read -r left base right has_base < <(parse_balance "$f")
                total_lines=$((left + right))
                has_base_field="$( [ "$has_base" -eq 1 ] && echo true || echo false )"
                local max=$left min=$right
                if [ "$right" -gt "$left" ]; then max=$right; min=$left; fi
                if [ "$min" -eq 0 ] && [ "$max" -eq 0 ]; then
                    imbalance_ratio="1.00"
                elif [ "$min" -eq 0 ]; then
                    empty_side="$( [ "$left" -eq 0 ] && echo L || echo R )"
                    imbalance_ratio=null
                else
                    local scaled=$((max * 100 / min))
                    imbalance_ratio="$(printf '%d.%02d' $((scaled/100)) $((scaled%100)))"
                fi

                # Stacked-PR aggregation.
                local stk_out stk_agg num all_ah has_ask min_pct
                stk_out="$("$SCRIPT_DIR/detect-stacked-pr.sh" --file "$f" --auto "$auto_stacked" --ask "$ask_stacked" --json 2>/dev/null || true)"
                read -r num all_ah has_ask min_pct < <(aggregate_stacked "$stk_out")
                if [ "$num" -gt 0 ]; then
                    if [ "$all_ah" -eq 1 ]; then
                        stacked_verdict='"AUTO_HEAD"'
                    elif [ "$has_ask" -eq 1 ]; then
                        stacked_verdict='"ASK"'
                    else
                        stacked_verdict='"MIXED"'
                    fi
                    stacked_pct="$min_pct"
                fi

                # Optional history retrieval.
                if $history_search && [ -x "$SCRIPT_DIR/historical-resolution-search.sh" ]; then
                    local hist_out
                    hist_out="$("$SCRIPT_DIR/historical-resolution-search.sh" --file "$f" --top 3 --json 2>/dev/null || true)"
                    if [ -n "$hist_out" ]; then
                        history_top_score="$(printf '%s' "$hist_out" | grep -oE '"score":[0-9]+' | head -n1 | sed -E 's/.*:([0-9]+)/\1/' || true)"
                        history_top_score="${history_top_score:-null}"
                    fi
                fi

                # Routing table (first match wins; cites H-NN heuristics).
                if [ "$num" -gt 0 ] && [ "$all_ah" -eq 1 ]; then
                    route="stacked-auto"; reason="stacked_pct=${min_pct}"; conf="high"           # H-06
                elif [ "$num" -gt 0 ] && [ "$has_ask" -eq 1 ]; then
                    route="llm-imbalanced"; reason="stacked_ask_pct=${min_pct}"; conf="medium"   # H-06
                elif [ "$total_lines" -gt "$large_threshold" ]; then
                    route="halt-decomposition"; reason="total=${total_lines}"; conf="none"        # H-11
                elif [ "$min" -eq 0 ] && [ "$max" -gt 0 ]; then
                    route="llm-imbalanced"; reason="empty_side=${empty_side}"; conf="medium"     # modify-delete
                elif [ "$min" -gt 0 ] && [ "$max" -ge "$((imbalance_threshold * min))" ]; then
                    route="llm-imbalanced"; reason="ratio=${imbalance_ratio}"; conf="high"       # H-02
                elif [ "$history_top_score" != null ] && [ "$history_top_score" -ge "$history_threshold" ]; then
                    route="llm-with-history"; reason="hist_score=${history_top_score}"; conf="medium" # H-05
                elif [ "$has_base" -eq 1 ]; then
                    route="sbse-recombine"; reason="balanced_lines=${left}/${right}"; conf="medium"   # H-02
                elif [ "$total_lines" -eq 0 ]; then
                    route="halt-other"; reason="no_conflict_blocks"; conf="none"
                else
                    route="llm-imbalanced"; reason="no_diff3=true"; conf="low"                    # H-06
                fi
            fi
        fi

        if $json; then
            [ "$first" -eq 1 ] || printf ','
            first=0
            printf '{"file":"%s","category":"%s","route":"%s","reason":"%s","confidence":"%s","signals":{"imbalance_ratio":%s,"total_lines":%d,"empty_side":%s,"has_base":%s,"stacked_verdict":%s,"stacked_pct":%s,"history_top_score":%s}}' \
                "$(json_escape "$f")" "$cat" "$route" "$(json_escape "$reason")" "$conf" \
                "$( [ "$imbalance_ratio" = null ] && echo null || printf '"%s"' "$imbalance_ratio" )" \
                "$total_lines" \
                "$( [ "$empty_side" = null ] && echo null || printf '"%s"' "$empty_side" )" \
                "$has_base_field" \
                "$stacked_verdict" \
                "$stacked_pct" \
                "$history_top_score"
        else
            printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$cat" "$route" "$reason" "$conf"
        fi
    done
    $json && printf ']\n'

    exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
