#!/usr/bin/env bash
set -euo pipefail

# prompt-context.sh — hard-capped cross-file context bundle (Rover-inspired,
# shell v1). Walks `git grep -w` BFS from identifier seeds extracted from the
# conflict block up to k hops, then emits Markdown (or JSON) with a strict
# budget (seeds, hits, bytes, k). Implements H-03 ("Rover k=4 optimal; deeper
# context degrades attention").
#
# This is the "lite" variant. tree-sitter / ctags / Lanser-CLI integration is
# deferred to a Python v2 plan in docs/research-synthesis.md.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Common pathspec exclusions (mirrors validate-resolution.sh and adds .lock).
EXCLUDE_PATHSPECS=(':!*.md' ':!*.txt' ':!*.rst' ':!docs/**' ':!references/**' ':!*.lock' ':!*.svg' ':!*.png')

# Keywords/noise filtered out of seed extraction.
NOISE_REGEX='^(if|else|for|while|do|done|return|true|false|null|None|True|False|let|var|const|fn|func|function|def|class|struct|enum|trait|interface|type|impl|pub|async|await|new|this|self|super|from|import|export|default|any|as|in|of|is|not|and|or|with|case|match|switch|break|continue|throw|catch|try|finally|yield|public|private|protected|static|void|int|char|bool|string|object|undefined|nil|begin|end|module|namespace|use|require)$'

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Collect conflict-block (left + right) text from a file. Skips base section.
extract_block_text() {
    local file="$1" in_block=0 section="" out=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '<<<<<<< '*) in_block=1; section=left ;;
            '||||||| '*) [ "$in_block" -eq 1 ] && section=base ;;
            '=======')   [ "$in_block" -eq 1 ] && section=right ;;
            '>>>>>>> '*) [ "$in_block" -eq 1 ] && in_block=0 ;;
            *)
                if [ "$in_block" -eq 1 ] && [ "$section" != base ]; then
                    out+="${line}"$'\n'
                fi ;;
        esac
    done < "$file"
    printf '%s' "$out"
}

# Extract unique identifier-like tokens from a text blob, filtered against
# noise list and a min-length 3.
extract_identifiers() {
    local text="$1"
    # Brace-wrap protects against pipefail when grep matches nothing.
    {
        printf '%s' "$text" \
            | { grep -oE '[A-Za-z_][A-Za-z0-9_]{2,}' || true; } \
            | awk -v noise="$NOISE_REGEX" '$0 !~ noise {print}' \
            | awk '!seen[$0]++'
    } || true
}

main() {
    command -v git >/dev/null || { echo "ERROR: git not found in PATH" >&2; exit 12; }
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repository" >&2; exit 11; }

    local file="" k=4 max_hits=48 max_bytes=12288 max_seeds=12
    local extra_seeds=() format=md

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --file) [ "$#" -ge 2 ] || { echo "ERROR: --file needs a path" >&2; exit 10; }; file="$2"; shift 2 ;;
            --symbol) [ "$#" -ge 2 ] || { echo "ERROR: --symbol needs a name" >&2; exit 10; }; extra_seeds+=("$2"); shift 2 ;;
            --k) [ "$#" -ge 2 ] || { echo "ERROR: --k needs a number" >&2; exit 10; }; k="$2"; shift 2 ;;
            --max-hits) [ "$#" -ge 2 ] || { echo "ERROR: --max-hits needs a number" >&2; exit 10; }; max_hits="$2"; shift 2 ;;
            --max-bytes) [ "$#" -ge 2 ] || { echo "ERROR: --max-bytes needs a number" >&2; exit 10; }; max_bytes="$2"; shift 2 ;;
            --max-seeds) [ "$#" -ge 2 ] || { echo "ERROR: --max-seeds needs a number" >&2; exit 10; }; max_seeds="$2"; shift 2 ;;
            --format) [ "$#" -ge 2 ] || { echo "ERROR: --format needs md|json" >&2; exit 10; }; format="$2"; shift 2 ;;
            --) shift; break ;;
            -*) echo "ERROR: unknown flag: $1" >&2; exit 10 ;;
            *) echo "ERROR: unexpected arg: $1" >&2; exit 10 ;;
        esac
    done
    [ -n "$file" ] || { echo "ERROR: --file is required" >&2; exit 10; }
    [ -r "$file" ] || { echo "ERROR: cannot read $file" >&2; exit 10; }
    # Canonicalize --file to a repo-relative path so the self-hit guard further
    # down matches `git grep`'s output regardless of how the caller spelled it
    # (`./foo`, absolute path, etc.). Falls back to the original string if the
    # path is not tracked.
    local repo_root canonical_file
    repo_root="$(git rev-parse --show-toplevel)"
    if [[ "$file" = "$repo_root/"* ]]; then
        file="${file#"$repo_root"/}"
    else
        canonical_file="$(git -C "$repo_root" ls-files --full-name -- "$file" 2>/dev/null | head -n1 || true)"
        [ -n "$canonical_file" ] && file="$canonical_file"
    fi
    for v in k max_hits max_bytes max_seeds; do
        case "${!v}" in ''|*[!0-9]*) echo "ERROR: --${v//_/-} must be an integer" >&2; exit 10 ;; esac
    done
    case "$format" in md|json) ;; *) echo "ERROR: --format must be md or json" >&2; exit 10 ;; esac

    # Seeds: extracted from conflict block, plus user-supplied --symbol, capped.
    local block_text auto_seeds combined_seeds
    block_text="$(extract_block_text "$file")"
    auto_seeds="$(extract_identifiers "$block_text")"
    combined_seeds="$(
        printf '%s\n' "${extra_seeds[@]+"${extra_seeds[@]}"}"
        printf '%s\n' "$auto_seeds"
    )"
    # dedupe preserving order; cap to max_seeds. Check the cap BEFORE appending
    # so `--max-seeds 0` honours its contract (no seeds appended at all).
    local seeds=()
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        [ "${#seeds[@]}" -ge "$max_seeds" ] && break
        seeds+=("$s")
    done < <(printf '%s\n' "$combined_seeds" | awk '!seen[$0]++')

    if [ "${#seeds[@]}" -eq 0 ]; then
        if [ "$format" = json ]; then
            printf '{"file":"%s","seeds":[],"hops":[],"budget":{"seeds":0,"hits":0,"bytes":0,"max_seeds":%d,"max_hits":%d,"max_bytes":%d,"k":%d,"truncated":false}}\n' \
                "$(json_escape "$file")" "$max_seeds" "$max_hits" "$max_bytes" "$k"
        else
            printf '# Prompt context: %s\n\nNo identifier seeds extracted from conflict block.\n' "$file"
        fi
        exit 2
    fi

    # BFS.
    declare -A visited=()
    local s; for s in "${seeds[@]}"; do visited["$s"]=1; done

    local hits_used=0 bytes_used=0 truncated=false
    declare -a hop_records=()
    local file_basename hop_h frontier next_frontier
    file_basename="${file##*/}"

    # frontier stored as newline-delimited string for portability
    frontier="$(printf '%s\n' "${seeds[@]}")"

    for ((hop_h=1; hop_h<=k; hop_h++)); do
        next_frontier=""
        local sym
        while IFS= read -r sym; do
            [ -n "$sym" ] || continue
            # git grep -n -w "$sym" -- excludes. Quote sym to be literal.
            local grep_out raw_out
            raw_out="$(git grep -n -w -F -- "$sym" ${EXCLUDE_PATHSPECS[@]+"${EXCLUDE_PATHSPECS[@]}"} 2>/dev/null || true)"
            grep_out="$(printf '%s' "$raw_out" | sort -u || true)"
            local hit
            while IFS= read -r hit; do
                [ -n "$hit" ] || continue
                local hf hl rest
                hf="${hit%%:*}"; rest="${hit#*:}"
                hl="${rest%%:*}"; rest="${rest#*:}"
                # skip the conflict file's lines that are inside the conflict block (they ARE the conflict text)
                [ "$hf" = "$file" ] && continue
                # budget check
                local rec_size=$(( ${#hit} + 1 ))
                if [ "$hits_used" -ge "$max_hits" ] || [ "$((bytes_used + rec_size))" -gt "$max_bytes" ]; then
                    truncated=true; break 2
                fi
                hop_records+=("${hop_h}|${sym}|${hf}|${hl}|${rest}")
                hits_used=$((hits_used + 1))
                bytes_used=$((bytes_used + rec_size))
                # extract identifiers from the matched line for next hop
                local new_id
                while IFS= read -r new_id; do
                    [ -n "$new_id" ] || continue
                    [ -n "${visited[$new_id]:-}" ] && continue
                    visited["$new_id"]=1
                    next_frontier+="${new_id}"$'\n'
                done < <(printf '%s\n' "$rest" | { grep -oE '[A-Za-z_][A-Za-z0-9_]{2,}' || true; } | awk -v noise="$NOISE_REGEX" '$0 !~ noise {print}')
            done <<< "$grep_out"
        done <<< "$frontier"
        frontier="$next_frontier"
        [ -z "${frontier// /}" ] && break
        # Don't invoke $truncated as a command (`true`/`false` are real
        # binaries on PATH); compare its string value explicitly.
        [ "$truncated" = true ] && break
    done

    # Emit.
    if [ "$format" = json ]; then
        printf '{"file":"%s","seeds":[' "$(json_escape "$file")"
        local i=0
        for s in "${seeds[@]}"; do
            [ "$i" -gt 0 ] && printf ','
            i=$((i+1))
            printf '"%s"' "$(json_escape "$s")"
        done
        printf '],"hops":['
        local hop_i=1 first_hop=1
        for ((hop_i=1; hop_i<=k; hop_i++)); do
            local hop_has=0
            local rec
            for rec in "${hop_records[@]+"${hop_records[@]}"}"; do
                [ "${rec%%|*}" = "$hop_i" ] && hop_has=1 && break
            done
            [ "$hop_has" -eq 0 ] && continue
            [ "$first_hop" -eq 1 ] || printf ','
            first_hop=0
            printf '{"depth":%d,"hits":[' "$hop_i"
            local first_rec=1
            for rec in "${hop_records[@]+"${hop_records[@]}"}"; do
                local rh="${rec%%|*}"
                [ "$rh" = "$hop_i" ] || continue
                IFS='|' read -r _ rsym rfile rline rsnip <<< "$rec"
                [ "$first_rec" -eq 1 ] || printf ','
                first_rec=0
                printf '{"symbol":"%s","file":"%s","line":%s,"snippet":"%s"}' \
                    "$(json_escape "$rsym")" "$(json_escape "$rfile")" "$rline" "$(json_escape "$rsnip")"
            done
            printf ']}'
        done
        printf '],"budget":{"seeds":%d,"hits":%d,"bytes":%d,"max_seeds":%d,"max_hits":%d,"max_bytes":%d,"k":%d,"truncated":%s}}\n' \
            "${#seeds[@]}" "$hits_used" "$bytes_used" "$max_seeds" "$max_hits" "$max_bytes" "$k" "$truncated"
    else
        printf '# Prompt context: %s\n\n' "$file"
        printf '## Seeds (%d)\n' "${#seeds[@]}"
        for s in "${seeds[@]}"; do printf -- '- `%s`\n' "$s"; done
        printf '\n'
        local hop_i=1
        for ((hop_i=1; hop_i<=k; hop_i++)); do
            local hop_has=0
            local rec
            for rec in "${hop_records[@]+"${hop_records[@]}"}"; do
                [ "${rec%%|*}" = "$hop_i" ] && hop_has=1 && break
            done
            [ "$hop_has" -eq 0 ] && continue
            printf '## Cross-references (k=%d)\n' "$hop_i"
            local cur_file=""
            for rec in "${hop_records[@]+"${hop_records[@]}"}"; do
                local rh="${rec%%|*}"
                [ "$rh" = "$hop_i" ] || continue
                IFS='|' read -r _ rsym rfile rline rsnip <<< "$rec"
                if [ "$rfile" != "$cur_file" ]; then
                    cur_file="$rfile"
                    printf '\n### %s\n' "$rfile"
                fi
                printf -- '- L%s (`%s`): `%s`\n' "$rline" "$rsym" "$rsnip"
            done
            printf '\n'
        done
        printf '## Budget\n'
        printf -- '- seeds: %d / %d\n' "${#seeds[@]}" "$max_seeds"
        printf -- '- hits: %d / %d\n' "$hits_used" "$max_hits"
        printf -- '- bytes: %d / %d\n' "$bytes_used" "$max_bytes"
        printf -- '- k: %d\n' "$k"
        printf -- '- truncated: %s\n' "$truncated"
    fi
    exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
