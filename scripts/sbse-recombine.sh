#!/usr/bin/env bash
set -euo pipefail

# sbse-recombine.sh — bounded deterministic line-combination candidate generator
# for "balanced" Other-category conflicts. Operationalises the 87%
# line-combination finding (LLM-vs-SBSE; H-02). Emission only; never writes to
# the worktree, never auto-applies a candidate. v1 enumerates 7 deterministic
# strategies; full RRHC (Random Restart Hill Climbing) with stochastic restarts
# is deferred to a Python v2 — see docs/research-synthesis.md.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/jaccard.sh
source "$SCRIPT_DIR/lib/jaccard.sh"

json_escape() {
    # With --include-content the input can be a multiline candidate body, so we
    # must escape the five JSON-named control chars and any remaining 0x00-0x1f
    # bytes as \u00xx; otherwise the surrounding JSON object is malformed and
    # the line-oriented sort/read pipeline downstream is broken by raw newlines.
    local s="$1" out="" i ch code
    for ((i = 0; i < ${#s}; i++)); do
        ch="${s:i:1}"
        case "$ch" in
            '\') out+='\\' ;;
            '"') out+='\"' ;;
            $'\b') out+='\b' ;;
            $'\f') out+='\f' ;;
            $'\n') out+='\n' ;;
            $'\r') out+='\r' ;;
            $'\t') out+='\t' ;;
            *)
                printf -v code '%d' "'$ch" 2>/dev/null || code=0
                if [ "$code" -ge 0 ] && [ "$code" -lt 32 ]; then
                    printf -v ch '\\u%04x' "$code"
                fi
                out+="$ch"
                ;;
        esac
    done
    printf '%s' "$out"
}

# Splits a string into lines preserving blanks, dropping only the trailing
# empty line after the final newline (so a one-line input emits one line).
split_lines() {
    local s="$1"
    case "$s" in *$'\n') s="${s%$'\n'}";; esac
    [ -z "$s" ] && return 0
    printf '%s\n' "$s"
}

# Parse the file's conflict blocks into parallel arrays.
parse_blocks() {
    local file="$1"
    BLOCK_LEFTS=(); BLOCK_BASES=(); BLOCK_RIGHTS=(); BLOCK_HAS_BASE=()
    local in_block=0 section="" left="" base="" right="" has_base=0 line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '<<<<<<< '*) in_block=1; section=left; left=""; base=""; right=""; has_base=0 ;;
            '||||||| '*) [ "$in_block" -eq 1 ] && { section=base; has_base=1; } ;;
            '=======')   [ "$in_block" -eq 1 ] && section=right ;;
            '>>>>>>> '*)
                if [ "$in_block" -eq 1 ]; then
                    BLOCK_LEFTS+=("$left"); BLOCK_BASES+=("$base")
                    BLOCK_RIGHTS+=("$right"); BLOCK_HAS_BASE+=("$has_base")
                    in_block=0
                fi ;;
            *)
                if [ "$in_block" -eq 1 ]; then
                    case "$section" in
                        left)  left+="${line}"$'\n' ;;
                        base)  base+="${line}"$'\n' ;;
                        right) right+="${line}"$'\n' ;;
                    esac
                fi ;;
        esac
    done < "$file"
}

# --- candidate generators (deterministic; pure functions of left/base/right) -
cand_ours_only()       { printf '%s' "$LEFT"; }
cand_theirs_only()     { printf '%s' "$RIGHT"; }
cand_left_then_right() { printf '%s%s' "$LEFT" "$RIGHT"; }
cand_right_then_left() { printf '%s%s' "$RIGHT" "$LEFT"; }

cand_union_dedup() {
    # left lines verbatim, then right lines not already in left, in right order.
    printf '%s' "$LEFT"
    while IFS= read -r r; do
        grep -Fxq -- "$r" <<< "$LEFT" || printf '%s\n' "$r"
    done < <(split_lines "$RIGHT")
}

cand_intersection() {
    # lines present in both sides, in left order. Force return 0 so a
    # last-line mismatch (grep -Fxq returning 1) does not propagate out.
    while IFS= read -r l; do
        grep -Fxq -- "$l" <<< "$RIGHT" && printf '%s\n' "$l"
    done < <(split_lines "$LEFT")
    return 0
}

# Requires non-empty base; otherwise returns 1 and the candidate is omitted.
cand_base_plus_additive() {
    [ -n "$BASE" ] || return 1
    printf '%s' "$BASE"
    # Order-preserving deduplication: sort -u would alphabetise lines and
    # scramble code structure, almost guaranteeing a non-compiling candidate.
    # `awk '!seen[$0]++'` keeps the first occurrence in left-then-right order.
    {
        split_lines "$LEFT"
        split_lines "$RIGHT"
    } | awk '!seen[$0]++' | while IFS= read -r l; do
        [ -n "$l" ] || continue
        grep -Fxq -- "$l" <<< "$BASE" || printf '%s\n' "$l"
    done
}

CANDIDATE_IDS=(ours-only theirs-only left-then-right right-then-left union-dedup intersection base-plus-additive)

# Count lines in a string (treats trailing-newline-only string as 0 lines).
count_lines() {
    local s="$1"
    [ -z "$s" ] && { echo 0; return; }
    printf '%s' "$s" | awk 'END {print NR}'
}

main() {
    command -v git >/dev/null || { echo "ERROR: git not found in PATH" >&2; exit 12; }
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repository" >&2; exit 11; }

    local file="" block_filter=0 top=3 max_lines=400 max_imbalance=3
    local include_content=false json=true

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --file) [ "$#" -ge 2 ] || { echo "ERROR: --file needs a path" >&2; exit 10; }; file="$2"; shift 2 ;;
            --block) [ "$#" -ge 2 ] || { echo "ERROR: --block needs a number" >&2; exit 10; }; block_filter="$2"; shift 2 ;;
            --top) [ "$#" -ge 2 ] || { echo "ERROR: --top needs a number" >&2; exit 10; }; top="$2"; shift 2 ;;
            --max-lines) [ "$#" -ge 2 ] || { echo "ERROR: --max-lines needs a number" >&2; exit 10; }; max_lines="$2"; shift 2 ;;
            --max-imbalance) [ "$#" -ge 2 ] || { echo "ERROR: --max-imbalance needs a number" >&2; exit 10; }; max_imbalance="$2"; shift 2 ;;
            --include-content) include_content=true; shift ;;
            --json) json=true; shift ;;
            --tsv) json=false; shift ;;
            --) shift; break ;;
            -*) echo "ERROR: unknown flag: $1" >&2; exit 10 ;;
            *) echo "ERROR: unexpected arg: $1" >&2; exit 10 ;;
        esac
    done
    [ -n "$file" ] || { echo "ERROR: --file is required" >&2; exit 10; }
    [ -r "$file" ] || { echo "ERROR: cannot read $file" >&2; exit 10; }
    for v in block_filter top max_lines max_imbalance; do
        case "${!v}" in ''|*[!0-9]*) echo "ERROR: --${v//_/-} must be an integer" >&2; exit 10 ;; esac
    done

    parse_blocks "$file"
    local n_blocks=${#BLOCK_LEFTS[@]}
    if [ "$n_blocks" -eq 0 ]; then
        if $json; then printf '{"file":"%s","blocks":[]}\n' "$(json_escape "$file")"; else echo "No conflict blocks in $file"; fi
        exit 2
    fi
    if [ "$block_filter" -gt 0 ] && [ "$block_filter" -gt "$n_blocks" ]; then
        echo "ERROR: --block $block_filter out of range (file has $n_blocks blocks)" >&2; exit 10
    fi

    # Buffered output to allow JSON object framing.
    $json && printf '{"file":"%s","thresholds":{"max_lines":%d,"max_imbalance":%d},"blocks":[' \
        "$(json_escape "$file")" "$max_lines" "$max_imbalance"

    local first_block=1
    local b
    for ((b=0; b<n_blocks; b++)); do
        local block_num=$((b + 1))
        [ "$block_filter" -gt 0 ] && [ "$block_filter" -ne "$block_num" ] && continue

        LEFT="${BLOCK_LEFTS[$b]}"
        BASE="${BLOCK_BASES[$b]}"
        RIGHT="${BLOCK_RIGHTS[$b]}"
        local has_base="${BLOCK_HAS_BASE[$b]}"
        local left_lines right_lines total min max
        left_lines="$(count_lines "$LEFT")"
        right_lines="$(count_lines "$RIGHT")"
        total=$((left_lines + right_lines))
        min=$left_lines; max=$right_lines
        if [ "$left_lines" -gt "$right_lines" ]; then max=$left_lines; min=$right_lines; fi

        local deferred=false deferral_reason=null
        if [ "$total" -gt "$max_lines" ]; then
            deferred=true
            deferral_reason="total=${total}>max_lines=${max_lines}"
        elif [ "$min" -gt 0 ] && [ "$max" -ge "$((max_imbalance * min))" ]; then
            deferred=true
            deferral_reason="imbalance=${max}/${min}>=${max_imbalance}x"
        fi

        # Emit block JSON header.
        if $json; then
            [ "$first_block" -eq 1 ] || printf ','
            first_block=0
            printf '{"block":%d,"left_lines":%d,"right_lines":%d,"has_base":%s,"deferred":%s,"deferral_reason":%s' \
                "$block_num" "$left_lines" "$right_lines" \
                "$( [ "$has_base" -eq 1 ] && echo true || echo false )" \
                "$deferred" \
                "$( [ "$deferral_reason" = null ] && echo null || printf '"%s"' "$(json_escape "$deferral_reason")" )"
        else
            printf 'Block %d (left=%d right=%d base=%s deferred=%s)\n' \
                "$block_num" "$left_lines" "$right_lines" "$has_base" "$deferred"
        fi

        if [ "$deferred" = true ]; then
            $json && printf ',"candidates":[],"verdict":"deferred"}' || true
            continue
        fi

        # Generate candidates, score, sort.
        local -a recs=()
        local id body score_l score_r score sha lines
        for id in "${CANDIDATE_IDS[@]}"; do
            if ! body="$("cand_${id//-/_}")"; then continue; fi
            # Skip degenerate empties only when all three buckets are empty too.
            score_l="$(jaccard_similarity_pct "$body" "$LEFT")"
            score_r="$(jaccard_similarity_pct "$body" "$RIGHT")"
            score=$(( (score_l + score_r) / 2 ))
            sha="$(printf '%s' "$body" | sha1sum | cut -d' ' -f1)"
            lines="$(count_lines "$body")"
            local content_field=""
            if $include_content; then
                content_field=",\"content\":\"$(json_escape "$body")\""
            fi
            recs+=("${score}|${id}|${lines}|${sha}|${content_field}")
        done

        # Sort by score desc, then id asc for stability.
        IFS=$'\n' read -r -d '' -a sorted < <(printf '%s\n' "${recs[@]}" | sort -t'|' -k1,1nr -k2,2 && printf '\0') || true

        # Determine verdict.
        local verdict="mixed" top1=0 top2=0 top3=0
        [ "${#sorted[@]}" -ge 1 ] && top1="${sorted[0]%%|*}"
        [ "${#sorted[@]}" -ge 2 ] && top2="${sorted[1]%%|*}"
        [ "${#sorted[@]}" -ge 3 ] && top3="${sorted[2]%%|*}"
        if [ "${#sorted[@]}" -eq 0 ]; then
            verdict="none"
        elif [ "$top1" -lt 50 ]; then
            verdict="low-confidence"
        elif [ "$top1" -ge 95 ] && [ "$((top1 - top2))" -ge 10 ]; then
            verdict="clear-winner"
        elif [ "${#sorted[@]}" -ge 3 ] && [ "$((top1 - top3))" -le 5 ]; then
            verdict="ambiguous"
        fi

        # Truncate to top N.
        local emit=("${sorted[@]:0:$top}")
        if $json; then
            printf ',"candidates":['
            local i=0 rec
            for rec in "${emit[@]}"; do
                IFS='|' read -r s_score s_id s_lines s_sha s_content <<< "$rec"
                [ "$i" -gt 0 ] && printf ','
                i=$((i + 1))
                printf '{"id":"%s","score":%d,"lines":%d,"sha1":"%s"%s}' \
                    "$s_id" "$s_score" "$s_lines" "$s_sha" "$s_content"
            done
            printf '],"verdict":"%s"}' "$verdict"
        else
            local rec
            for rec in "${emit[@]}"; do
                IFS='|' read -r s_score s_id s_lines s_sha s_content <<< "$rec"
                printf '  %-22s score=%-3d lines=%-3d sha1=%s\n' "$s_id" "$s_score" "$s_lines" "$s_sha"
            done
            printf '  verdict: %s\n' "$verdict"
        fi
    done

    $json && printf ']}\n'
    exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
