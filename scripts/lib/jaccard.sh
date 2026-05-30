# Whitespace-normalised line-set Jaccard similarity, as a percentage 0..100.
#
# Source this file from another script:
#
#     # shellcheck source=lib/jaccard.sh
#     source "${BASH_SOURCE%/*}/lib/jaccard.sh"
#     pct="$(jaccard_similarity_pct "$left" "$right")"
#
# Each side is treated as a set of non-empty lines after stripping internal
# whitespace and deduplicating. Two empty sides score 100. The same algorithm
# (originally inlined in scripts/detect-stacked-pr.sh) is reused by scripts that
# need a deterministic line-overlap score: detect-stacked-pr, sbse-recombine.
#
# Pure function: no side effects, no I/O beyond stdout.

jaccard_similarity_pct() {
    local left="$1" right="$2"
    local norm_left norm_right left_count right_count both_count union_count
    norm_left="$(printf '%s\n' "$left" | sed -E 's/[[:space:]]+//g' | awk 'NF' | sort -u)"
    norm_right="$(printf '%s\n' "$right" | sed -E 's/[[:space:]]+//g' | awk 'NF' | sort -u)"
    left_count="$(printf '%s\n' "$norm_left" | awk 'NF {n++} END {print n + 0}')"
    right_count="$(printf '%s\n' "$norm_right" | awk 'NF {n++} END {print n + 0}')"
    if [ "$left_count" -eq 0 ] && [ "$right_count" -eq 0 ]; then
        echo 100
        return
    fi
    both_count="$(comm -12 <(printf '%s\n' "$norm_left") <(printf '%s\n' "$norm_right") | awk 'NF {n++} END {print n + 0}')"
    union_count=$((left_count + right_count - both_count))
    if [ "$union_count" -eq 0 ]; then
        echo 100
    else
        echo $((both_count * 100 / union_count))
    fi
}
