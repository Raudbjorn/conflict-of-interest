#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/jaccard.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/jaccard.sh"

threshold_auto=95
threshold_ask=70
input_file=""
json=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --file) [ "$#" -ge 2 ] || { echo "ERROR: --file needs a path" >&2; exit 10; }; input_file="$2"; shift 2 ;;
        --auto) [ "$#" -ge 2 ] || { echo "ERROR: --auto needs a number" >&2; exit 10; }; threshold_auto="$2"; shift 2 ;;
        --ask) [ "$#" -ge 2 ] || { echo "ERROR: --ask needs a number" >&2; exit 10; }; threshold_ask="$2"; shift 2 ;;
        --json) json=true; shift ;;
        --) shift; break ;;
        -*) echo "ERROR: unknown flag: $1" >&2; exit 10 ;;
        *) echo "ERROR: unexpected arg: $1" >&2; exit 10 ;;
    esac
done

if [ -n "$input_file" ]; then
    [ -r "$input_file" ] || { echo "ERROR: cannot read $input_file" >&2; exit 10; }
    input="$(cat "$input_file")"
else
    input="$(cat)"
fi

similarity() { jaccard_similarity_pct "$@"; }

verdicts=()
in_block=0
section=""
left=""
base=""
right=""
has_base=0
block=0

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        '<<<<<<< '*)
            in_block=1; section=left; left=""; base=""; right=""; has_base=0 ;;
        '||||||| '*)
            [ "$in_block" -eq 1 ] && { section=base; has_base=1; } ;;
        '=======')
            [ "$in_block" -eq 1 ] && section=right ;;
        '>>>>>>> '*)
            if [ "$in_block" -eq 1 ]; then
                block=$((block + 1))
                if [ "$has_base" -eq 0 ]; then
                    verdicts+=("${block}|NO_DIFF3|")
                elif [ -z "$(printf '%s' "$base" | tr -d '[:space:]')" ]; then
                    pct="$(similarity "$left" "$right")"
                    if [ "$pct" -ge "$threshold_auto" ]; then verdict=AUTO_HEAD
                    elif [ "$pct" -ge "$threshold_ask" ]; then verdict=ASK
                    else verdict=DIVERGE
                    fi
                    verdicts+=("${block}|${verdict}|${pct}")
                else
                    pct="$(similarity "$left" "$right")"
                    verdicts+=("${block}|NON_EMPTY_BASE|${pct}")
                fi
                in_block=0; section=""
            fi ;;
        *)
            if [ "$in_block" -eq 1 ]; then
                case "$section" in
                    left) left+="${line}"$'\n' ;;
                    base) base+="${line}"$'\n' ;;
                    right) right+="${line}"$'\n' ;;
                esac
            fi ;;
    esac
done <<< "$input"

if [ "${#verdicts[@]}" -eq 0 ]; then
    $json && echo '{"blocks":[]}' || echo "No conflict blocks found."
    exit 1
fi

if $json; then
    printf '{"thresholds":{"auto":%d,"ask":%d},"blocks":[' "$threshold_auto" "$threshold_ask"
    for i in "${!verdicts[@]}"; do
        IFS='|' read -r idx verdict pct <<< "${verdicts[$i]}"
        [ "$i" -gt 0 ] && printf ','
        printf '{"block":%d,"verdict":"%s","similarity":%s}' "$idx" "$verdict" "${pct:-null}"
    done
    printf ']}\n'
else
    printf 'Conflict blocks: %d\n' "${#verdicts[@]}"
    printf 'Thresholds: auto>=%s%%, ask>=%s%%\n\n' "$threshold_auto" "$threshold_ask"
    printf '%-6s %-16s %-10s\n' Block Verdict Similarity
    for entry in "${verdicts[@]}"; do
        IFS='|' read -r idx verdict pct <<< "$entry"
        printf '#%-5s %-16s %s\n' "$idx" "$verdict" "${pct:+${pct}%}"
    done
fi

