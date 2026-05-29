#!/usr/bin/env bash
set -euo pipefail

top=3
max_merges=200
since=""
timeout_seconds=20
language=""
base_ref=""
other_ref=""
include_snippets=false
json=false
files=()
symbols=()

usage() {
    cat <<'EOF'
Usage: historical-resolution-search.sh [options]

Find similar historical merge-conflict resolutions in the local git repository.

Options:
  --file PATH              Current conflicted file; repeatable
  --symbol NAME            Symbol/token to bias ranking; repeatable
  --language ID            Optional language filter (py, ts, js, java, c, ...)
  --base REF               Optional current conflict base ref (recorded in output)
  --other REF              Optional current conflict other ref (recorded in output)
  --top N                  Number of examples to return (default: 3)
  --max-merges N           Maximum merge commits to inspect (default: 200)
  --since DATE             Limit candidate merge commits by git date expression
  --timeout-seconds N      Stop searching after N seconds (default: 20)
  --include-snippets       Include bounded parent/result snippets in output
  --json                   Emit JSON
  --help                   Show this help
EOF
}

die_usage() {
    echo "ERROR: $1" >&2
    exit 10
}

json_escape() {
    awk '
        BEGIN { ORS = "" }
        {
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            gsub(/\t/, "\\t")
            gsub(/\r/, "\\r")
            if (NR > 1) {
                printf "\\n"
            }
            printf "%s", $0
        }
    '
}

json_string() {
    printf '"%s"' "$(printf '%s' "$1" | json_escape)"
}

json_array_csv() {
    local csv="$1" first=true item
    printf '['
    if [ -n "$csv" ]; then
        IFS=',' read -r -a items <<< "$csv"
        for item in "${items[@]}"; do
            [ -n "$item" ] || continue
            if $first; then first=false; else printf ','; fi
            json_string "$item"
        done
    fi
    printf ']'
}

emit_query_json() {
    local first=true file sym
    printf '{"files":['
    for file in "${files[@]}"; do
        if $first; then first=false; else printf ','; fi
        json_string "$file"
    done
    printf '],"symbols":['
    first=true
    for sym in "${symbols[@]}"; do
        if $first; then first=false; else printf ','; fi
        json_string "$sym"
    done
    printf '],"language":'
    if [ -n "$language" ]; then json_string "$language"; else printf 'null'; fi
    printf ',"base":'
    if [ -n "$base_ref" ]; then json_string "$base_ref"; else printf 'null'; fi
    printf ',"other":'
    if [ -n "$other_ref" ]; then json_string "$other_ref"; else printf 'null'; fi
    printf ',"top":%d,"max_merges":%d,"since":' "$top" "$max_merges"
    if [ -n "$since" ]; then json_string "$since"; else printf 'null'; fi
    printf ',"timeout_seconds":%d,"include_snippets":' "$timeout_seconds"
    if $include_snippets; then printf 'true'; else printf 'false'; fi
    printf '}'
}

no_signal() {
    local reason="$1"
    if $json; then
        printf '{"version":1,"query":'
        emit_query_json
        printf ',"status":"no_signal","reason":'
        json_string "$reason"
        printf ',"matches":[]}\n'
    else
        echo "No historical resolution signal: $reason" >&2
    fi
    exit 2
}

is_positive_int() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --file) [ "$#" -ge 2 ] || die_usage "--file needs a path"; files+=("$2"); shift 2 ;;
        --symbol) [ "$#" -ge 2 ] || die_usage "--symbol needs a name"; symbols+=("$2"); shift 2 ;;
        --language) [ "$#" -ge 2 ] || die_usage "--language needs an id"; language="$2"; shift 2 ;;
        --base) [ "$#" -ge 2 ] || die_usage "--base needs a ref"; base_ref="$2"; shift 2 ;;
        --other) [ "$#" -ge 2 ] || die_usage "--other needs a ref"; other_ref="$2"; shift 2 ;;
        --top) [ "$#" -ge 2 ] || die_usage "--top needs a number"; is_positive_int "$2" || die_usage "--top must be a positive integer"; top="$2"; shift 2 ;;
        --max-merges) [ "$#" -ge 2 ] || die_usage "--max-merges needs a number"; is_positive_int "$2" || die_usage "--max-merges must be a positive integer"; max_merges="$2"; shift 2 ;;
        --since) [ "$#" -ge 2 ] || die_usage "--since needs a date"; since="$2"; shift 2 ;;
        --timeout-seconds) [ "$#" -ge 2 ] || die_usage "--timeout-seconds needs a number"; is_positive_int "$2" || die_usage "--timeout-seconds must be a positive integer"; timeout_seconds="$2"; shift 2 ;;
        --include-snippets) include_snippets=true; shift ;;
        --json) json=true; shift ;;
        --help) usage; exit 0 ;;
        --) shift; break ;;
        -*) die_usage "unknown flag: $1" ;;
        *) die_usage "unexpected arg: $1" ;;
    esac
done

command -v git >/dev/null || { echo "ERROR: git not found in PATH" >&2; exit 12; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repository" >&2; exit 11; }

if [ "$(git rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ]; then
    no_signal "shallow_repository"
fi

if git config --get-regexp '^remote\..*\.promisor$' 2>/dev/null | grep -q 'true'; then
    no_signal "partial_clone_promisor"
fi

if ! { git merge-tree -h 2>&1 || true; } | grep -q -- '--write-tree'; then
    if $json; then
        no_signal "merge_tree_unavailable"
    fi
    echo "ERROR: git merge-tree --write-tree is required" >&2
    exit 12
fi

if [ "${#files[@]}" -eq 0 ]; then
    while IFS= read -r path; do
        [ -n "$path" ] && files+=("$path")
    done < <(git diff --name-only --diff-filter=U)
fi

normalize_lines() {
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | awk 'NF' | sort -u
}

extract_current_conflict_lines() {
    local file="$1"
    [ -r "$file" ] || return 0
    awk '
        /^<<<<<<< / { in_block = 1; section = "left"; next }
        in_block && /^\|\|\|\|\|\|\| / { section = "base"; next }
        in_block && /^=======$/ { section = "right"; next }
        in_block && /^>>>>>>> / { in_block = 0; section = ""; next }
        in_block && (section == "left" || section == "right") { print }
    ' "$file"
}

language_for_path() {
    case "$1" in
        *.py) echo py ;;
        *.ts) echo ts ;;
        *.tsx) echo tsx ;;
        *.js) echo js ;;
        *.jsx) echo jsx ;;
        *.mjs) echo js ;;
        *.rs) echo rust ;;
        *.go) echo go ;;
        *.java) echo java ;;
        *.kt) echo kotlin ;;
        *.scala) echo scala ;;
        *.rb) echo ruby ;;
        *.ex|*.exs) echo elixir ;;
        *.c|*.h) echo c ;;
        *.cc|*.cpp|*.cxx|*.hpp|*.hh) echo cpp ;;
        *.swift) echo swift ;;
        *.dart) echo dart ;;
        *.php) echo php ;;
        *.json) echo json ;;
        *.yml|*.yaml) echo yaml ;;
        *.toml) echo toml ;;
        *.md) echo markdown ;;
        *) echo "" ;;
    esac
}

basename_of() {
    local path="$1"
    printf '%s' "${path##*/}"
}

extension_of() {
    local base
    base="$(basename_of "$1")"
    if [[ "$base" == *.* ]]; then
        printf '%s' "${base##*.}"
    fi
}

ratio_decimal() {
    local left="$1" right="$2" mode="$3" tmp_left tmp_right left_count right_count both_count denom
    tmp_left="$(mktemp "${TMPDIR:-/tmp}/history-left.XXXXXX")"
    tmp_right="$(mktemp "${TMPDIR:-/tmp}/history-right.XXXXXX")"
    printf '%s\n' "$left" | normalize_lines > "$tmp_left"
    printf '%s\n' "$right" | normalize_lines > "$tmp_right"
    left_count="$(awk 'NF {n++} END {print n + 0}' "$tmp_left")"
    right_count="$(awk 'NF {n++} END {print n + 0}' "$tmp_right")"
    both_count="$(comm -12 "$tmp_left" "$tmp_right" | awk 'NF {n++} END {print n + 0}')"
    if [ "$mode" = "jaccard" ]; then
        denom=$((left_count + right_count - both_count))
    else
        denom="$left_count"
    fi
    if [ "$denom" -eq 0 ]; then
        printf 'null'
    else
        awk -v both="$both_count" -v denom="$denom" 'BEGIN { printf "%.2f", both / denom }'
    fi
    rm -f "$tmp_left" "$tmp_right"
}

contains_path() {
    local needle="$1" file
    for file in "${files[@]}"; do
        [ "$file" = "$needle" ] && return 0
    done
    return 1
}

matches_basename() {
    local needle_base file
    needle_base="$(basename_of "$1")"
    for file in "${files[@]}"; do
        [ "$(basename_of "$file")" = "$needle_base" ] && return 0
    done
    return 1
}

matches_extension() {
    local ext file
    ext="$(extension_of "$1")"
    [ -n "$ext" ] || return 1
    for file in "${files[@]}"; do
        [ "$(extension_of "$file")" = "$ext" ] && return 0
    done
    return 1
}

merge_parents() {
    git show -s --format=%P "$1"
}

merge_tree_output() {
    local p1="$1" p2="$2"
    git merge-tree --write-tree "$p1" "$p2" 2>/dev/null || true
}

conflicted_paths_from_merge_tree() {
    awk '
        /^[0-9]{6} [0-9a-f]+ [123]\t/ {
            sub(/^[^\t]*\t/, "")
            print
        }
    ' | sort -u
}

stage_blob_for_path() {
    local stage="$1" path="$2"
    awk -v stage="$stage" -v path="$path" '
        BEGIN { FS = "\t" }
        $2 == path {
            split($1, parts, " ")
            if (parts[3] == stage) {
                print parts[2]
                exit
            }
        }
    '
}

blob_content() {
    local blob="$1"
    [ -n "$blob" ] || return 1
    git cat-file -p "$blob" 2>/dev/null
}

matched_symbols_for_text() {
    local text="$1" matched=() sym
    for sym in "${symbols[@]}"; do
        [ -n "$sym" ] || continue
        if printf '%s\n' "$text" | grep -Fq -- "$sym"; then
            matched+=("$sym")
        fi
    done
    (IFS=','; printf '%s' "${matched[*]-}")
}

bounded_snippet() {
    head -n 40 | awk '
        BEGIN { limit = 4000; used = 0 }
        {
            line = $0
            if (used + length(line) + 1 > limit) {
                exit
            }
            print line
            used += length(line) + 1
        }
    '
}

emit_snippets_json() {
    local commit="$1" path="$2" parents mt_out blob2 blob3 p2 p3 result parents_text result_text
    parents="$(merge_parents "$commit")"
    read -r p2 p3 _ <<< "$parents"
    mt_out="$(merge_tree_output "$p2" "$p3")"
    blob2="$(printf '%s\n' "$mt_out" | stage_blob_for_path 2 "$path")"
    blob3="$(printf '%s\n' "$mt_out" | stage_blob_for_path 3 "$path")"
    p2="$(blob_content "$blob2" 2>/dev/null | bounded_snippet || true)"
    p3="$(blob_content "$blob3" 2>/dev/null | bounded_snippet || true)"
    parents_text="$(printf '%s\n--- other parent ---\n%s\n' "$p2" "$p3" | bounded_snippet)"
    result="$(git show "$commit:$path" 2>/dev/null | bounded_snippet || true)"
    result_text="$result"
    printf '{"parents":'
    json_string "$parents_text"
    printf ',"result":'
    json_string "$result_text"
    printf '}'
}

current_lines=""
for file in "${files[@]}"; do
    current_lines+="$(
        extract_current_conflict_lines "$file"
    )"$'\n'
done
current_lines="$(printf '%s\n' "$current_lines" | normalize_lines)"

[ -n "$current_lines" ] || no_signal "no_current_conflict_context"

if ! git log --merges -n1 --format=%H >/dev/null 2>&1 || [ -z "$(git log --merges -n1 --format=%H)" ]; then
    no_signal "no_merge_commits"
fi

candidate_file="$(mktemp "${TMPDIR:-/tmp}/history-matches.XXXXXX")"
trap 'rm -f "$candidate_file"' EXIT

start_epoch="$(date +%s)"
merge_index=0
timed_out=false

if [ -n "$since" ]; then
    mapfile -t merge_commits < <(git log --merges --format=%H --max-count="$max_merges" --since="$since")
else
    mapfile -t merge_commits < <(git log --merges --format=%H --max-count="$max_merges")
fi

for commit in "${merge_commits[@]}"; do
    merge_index=$((merge_index + 1))
    now="$(date +%s)"
    if [ $((now - start_epoch)) -ge "$timeout_seconds" ]; then
        timed_out=true
        break
    fi

    parents="$(merge_parents "$commit")"
    read -r parent1 parent2 parent3 _ <<< "$parents"
    [ -n "$parent1" ] && [ -n "$parent2" ] || continue
    [ -z "${parent3:-}" ] || continue

    if mt_out="$(git merge-tree --write-tree "$parent1" "$parent2" 2>/dev/null)"; then
        continue
    else
        mt_rc=$?
        [ "$mt_rc" -eq 1 ] || continue
    fi

    while IFS= read -r candidate_path; do
        [ -n "$candidate_path" ] || continue
        candidate_language="$(language_for_path "$candidate_path")"
        if [ -n "$language" ] && [ "$candidate_language" != "$language" ]; then
            continue
        fi

        blob2="$(printf '%s\n' "$mt_out" | stage_blob_for_path 2 "$candidate_path")"
        blob3="$(printf '%s\n' "$mt_out" | stage_blob_for_path 3 "$candidate_path")"
        [ -n "$blob2" ] && [ -n "$blob3" ] || continue

        parent2_text="$(blob_content "$blob2" 2>/dev/null || true)"
        parent3_text="$(blob_content "$blob3" 2>/dev/null || true)"
        [ -n "$parent2_text$parent3_text" ] || continue

        result_text="$(git show "$commit:$candidate_path" 2>/dev/null || true)"
        [ -n "$result_text" ] || continue
        [ "$result_text" != "$parent2_text" ] || continue
        [ "$result_text" != "$parent3_text" ] || continue

        parent_lines="$(printf '%s\n%s\n' "$parent2_text" "$parent3_text" | normalize_lines)"
        result_lines="$(printf '%s\n' "$result_text" | normalize_lines)"
        line_jaccard="$(ratio_decimal "$current_lines" "$parent_lines" jaccard)"
        recombination="$(ratio_decimal "$result_lines" "$parent_lines" subset)"

        text_for_symbols="$(printf '%s\n%s\n%s\n%s\n' "$candidate_path" "$parent2_text" "$parent3_text" "$result_text")"
        matched_symbols="$(matched_symbols_for_text "$text_for_symbols")"
        matched_count=0
        [ -z "$matched_symbols" ] || matched_count="$(awk -F, '{print NF}' <<< "$matched_symbols")"

        path_bonus=0
        signals=()
        if contains_path "$candidate_path"; then
            path_bonus=$((path_bonus + 35))
            signals+=("same_path")
        elif matches_basename "$candidate_path"; then
            path_bonus=$((path_bonus + 20))
            signals+=("same_basename")
        elif matches_extension "$candidate_path"; then
            path_bonus=$((path_bonus + 10))
            signals+=("same_extension")
        fi
        if [ -n "$language" ] || [ -n "$candidate_language" ]; then
            if [ -n "$candidate_language" ]; then
                signals+=("language:${candidate_language}")
            fi
        fi
        if [ "$matched_count" -gt 0 ]; then
            signals+=("symbol_overlap")
        fi
        if [ "$recombination" != "null" ] && awk -v r="$recombination" 'BEGIN { exit !(r >= 0.80) }'; then
            signals+=("high_recombination")
        fi

        score="$(
            awk \
                -v path_bonus="$path_bonus" \
                -v matched="$matched_count" \
                -v jaccard="$line_jaccard" \
                -v recomb="$recombination" \
                -v idx="$merge_index" \
                -v max="$max_merges" '
                BEGIN {
                    j = (jaccard == "null") ? 0 : jaccard
                    r = (recomb == "null") ? 0 : recomb
                    recency = 10 - int((idx - 1) * 10 / max)
                    s = path_bonus + (matched * 15) + int(j * 35) + int(r * 10) + recency
                    if (s > 100) s = 100
                    if (s < 0) s = 0
                    print s
                }'
        )"
        date="$(git show -s --format=%cI "$commit")"
        subject="$(git show -s --format=%s "$commit" | tr '\t' ' ')"
        signal_csv="$(IFS=','; printf '%s' "${signals[*]-}")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$score" "$commit" "$date" "$candidate_path" "$candidate_language" \
            "$line_jaccard" "$recombination" "$matched_symbols" "$signal_csv" "$subject" \
            >> "$candidate_file"
    done < <(printf '%s\n' "$mt_out" | conflicted_paths_from_merge_tree)
done

if [ ! -s "$candidate_file" ]; then
    if $timed_out; then
        no_signal "timeout"
    fi
    no_signal "no_conflicted_candidate_paths"
fi

mapfile -t matches < <(sort -t $'\t' -k1,1nr -k3,3r -k2,2 "$candidate_file" | head -n "$top")

if $json; then
    printf '{"version":1,"query":'
    emit_query_json
    printf ',"status":"matches","reason":null,"matches":['
    for i in "${!matches[@]}"; do
        IFS=$'\t' read -r score commit date path candidate_language line_jaccard recombination matched_symbols signals subject <<< "${matches[$i]}"
        [ "$i" -gt 0 ] && printf ','
        printf '{"commit":'
        json_string "$commit"
        printf ',"date":'
        json_string "$date"
        printf ',"subject":'
        json_string "$subject"
        printf ',"path":'
        json_string "$path"
        printf ',"language":'
        if [ -n "$candidate_language" ]; then json_string "$candidate_language"; else printf 'null'; fi
        printf ',"score":%d,"line_jaccard":%s,"recombination_ratio":%s,"matched_symbols":' "$score" "$line_jaccard" "$recombination"
        json_array_csv "$matched_symbols"
        printf ',"signals":'
        json_array_csv "$signals"
        printf ',"inspect":'
        json_string "git show $commit -- $path"
        printf ',"snippets":'
        if $include_snippets; then
            emit_snippets_json "$commit" "$path"
        else
            printf 'null'
        fi
        printf '}'
    done
    printf ']}\n'
else
    printf 'Historical resolution matches: %d\n' "${#matches[@]}"
    for match in "${matches[@]}"; do
        IFS=$'\t' read -r score commit date path candidate_language line_jaccard recombination matched_symbols signals subject <<< "$match"
        printf '\n%s %s\n' "$commit" "$subject"
        printf '  date: %s\n' "$date"
        printf '  path: %s\n' "$path"
        printf '  language: %s\n' "${candidate_language:-unknown}"
        printf '  score: %s\n' "$score"
        printf '  line_jaccard: %s\n' "$line_jaccard"
        printf '  recombination_ratio: %s\n' "$recombination"
        printf '  matched_symbols: %s\n' "${matched_symbols:-none}"
        printf '  signals: %s\n' "${signals:-none}"
        printf '  inspect: git show %s -- %s\n' "$commit" "$path"
        if $include_snippets; then
            printf '  snippets: available with --json for structured consumption\n'
        fi
    done
fi

exit 0
