#!/usr/bin/env bash
set -euo pipefail

# validate-and-reprompt.sh — bounded debug-prompt artifact loop around
# validate-resolution.sh. On validation failure, writes a reprompt.md the
# agent reads and re-resolves from, then exits with code 5 to signal "retry
# requested". On retry budget exhaustion, exits with the original code.
#
# CRITICAL CONTRACT: this script NEVER calls an LLM, reaches the network, or
# touches anything outside the working tree and .git/conflict-resolver/. A
# dedicated test asserts the emitted artifact carries no http/api endpoints.
#
# LLMinus-inspired pattern (H-05). Claude is the orchestrator; this script is
# the deterministic glue.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

main() {
    command -v git >/dev/null || { echo "ERROR: git not found in PATH" >&2; exit 12; }
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repository" >&2; exit 11; }

    local typecheck="" test_cmd="" max_iters=1
    local include_paths=()
    local git_dir state_file reprompt_out
    git_dir="$(git rev-parse --git-dir)"
    state_file="$git_dir/conflict-resolver/reprompt-state.json"
    reprompt_out="$git_dir/conflict-resolver/reprompt.md"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --typecheck) [ "$#" -ge 2 ] || { echo "ERROR: --typecheck needs a command" >&2; exit 10; }; typecheck="$2"; shift 2 ;;
            --test) [ "$#" -ge 2 ] || { echo "ERROR: --test needs a command" >&2; exit 10; }; test_cmd="$2"; shift 2 ;;
            --max-iterations) [ "$#" -ge 2 ] || { echo "ERROR: --max-iterations needs a number" >&2; exit 10; }; max_iters="$2"; shift 2 ;;
            --state-file) [ "$#" -ge 2 ] || { echo "ERROR: --state-file needs a path" >&2; exit 10; }; state_file="$2"; shift 2 ;;
            --reprompt-out) [ "$#" -ge 2 ] || { echo "ERROR: --reprompt-out needs a path" >&2; exit 10; }; reprompt_out="$2"; shift 2 ;;
            --include-path) [ "$#" -ge 2 ] || { echo "ERROR: --include-path needs a pattern" >&2; exit 10; }; include_paths+=("$2"); shift 2 ;;
            --) shift; break ;;
            -*) echo "ERROR: unknown flag: $1" >&2; exit 10 ;;
            *) echo "ERROR: unexpected arg: $1" >&2; exit 10 ;;
        esac
    done
    case "$max_iters" in ''|*[!0-9]*) echo "ERROR: --max-iterations must be an integer" >&2; exit 10 ;; esac

    # Read iteration count from state file (1-line JSON-ish).
    local iter=0
    if [ -f "$state_file" ]; then
        iter="$(grep -oE '"iteration":[ ]*[0-9]+' "$state_file" | head -n1 | grep -oE '[0-9]+' | head -n1 || true)"
        iter="${iter:-0}"
    fi

    # Build validate-resolution.sh args.
    local v_args=()
    [ -n "$typecheck" ] && v_args+=(--typecheck "$typecheck")
    [ -n "$test_cmd" ] && v_args+=(--test "$test_cmd")
    local p
    for p in ${include_paths[@]+"${include_paths[@]}"}; do v_args+=(--include-path "$p"); done

    # Run validate-resolution.sh capturing combined output. Echo to terminal so
    # the user still sees the failure live.
    local output rc=0
    output="$("$SCRIPT_DIR/validate-resolution.sh" ${v_args[@]+"${v_args[@]}"} 2>&1)" || rc=$?
    printf '%s\n' "$output"

    if [ "$rc" -eq 0 ]; then
        rm -f "$state_file" "$reprompt_out" 2>/dev/null || true
        exit 0
    fi

    # Only exit codes 1..4 are retry-able (markers, whitespace, typecheck, tests).
    case "$rc" in
        1|2|3|4) ;;
        *) exit "$rc" ;;
    esac

    if [ "$iter" -ge "$max_iters" ]; then
        echo "HALT — reprompt budget exhausted (iteration $iter/$max_iters); underlying exit $rc" >&2
        exit "$rc"
    fi

    iter=$((iter + 1))
    mkdir -p "$(dirname "$reprompt_out")"

    # Identify candidate files from validate output. Patterns: "path:line:col" or
    # "path:line" or unmerged paths from `git diff --name-only --diff-filter=U`.
    local candidate_files cand_list=""
    candidate_files="$(printf '%s\n' "$output" \
        | grep -oE '[A-Za-z0-9_./-]+:[0-9]+(:[0-9]+)?' \
        | awk -F: '{print $1}' \
        | awk '!seen[$0]++' \
        | grep -v '^.*-resolution\.sh$' \
        || true)"
    # Drop candidates that aren't real files in the worktree (filters dates,
    # URLs, accidental token matches).
    candidate_files="$(printf '%s\n' "$candidate_files" | while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -e "$f" ] && printf '%s\n' "$f"
    done || true)"
    # Always include unmerged paths if any.
    while IFS= read -r u; do
        [ -n "$u" ] || continue
        cand_list+="${u}"$'\n'
    done < <(git diff --name-only --diff-filter=U 2>/dev/null || true)
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        cand_list+="${f}"$'\n'
    done <<< "$candidate_files"
    cand_list="$(printf '%s' "$cand_list" | awk '!seen[$0]++ && NF')"

    # Reason label by exit code.
    local reason
    case "$rc" in
        1) reason="conflict markers remain" ;;
        2) reason="whitespace check failed (--cached)" ;;
        3) reason="typecheck failed" ;;
        4) reason="tests failed" ;;
    esac

    # Tail to last 60 lines of output.
    local tail_output
    tail_output="$(printf '%s\n' "$output" | tail -n 60)"

    {
        printf '# Reprompt — validation failed (iteration %d/%d)\n\n' "$iter" "$max_iters"
        printf '## Failure\n'
        printf -- '- Exit code: %d (%s)\n' "$rc" "$reason"
        printf -- '- Command: `validate-resolution.sh%s%s`\n' \
            "$( [ -n "$typecheck" ] && printf ' --typecheck %q' "$typecheck" )" \
            "$( [ -n "$test_cmd" ] && printf ' --test %q' "$test_cmd" )"
        printf '\n### Last 60 lines of validation output\n\n'
        printf '```\n%s\n```\n\n' "$tail_output"
        printf '## Files involved\n'
        if [ -n "$cand_list" ]; then
            while IFS= read -r f; do
                printf -- '- `%s`\n' "$f"
            done <<< "$cand_list"
        else
            printf -- '- (no specific files identified; inspect the output above)\n'
        fi
        printf '\n## Instruction\n\n'
        printf 'Re-resolve the file(s) above so the failing check passes. Preserve the\n'
        printf 'recorded resolution intent from the per-file Decision Record (Step 3i).\n'
        printf 'Do not introduce changes unrelated to the failure. After re-resolving, run:\n\n'
        printf '```\n'
        printf '%s/validate-and-reprompt.sh' "$SCRIPT_DIR"
        [ -n "$typecheck" ] && printf ' --typecheck %q' "$typecheck"
        [ -n "$test_cmd" ] && printf ' --test %q' "$test_cmd"
        printf ' --max-iterations %d\n' "$max_iters"
        printf '```\n\n'
        printf 'If the same failure recurs, HALT and surface the conflict and this artifact\n'
        printf 'to the user. Abstention beats a wrong merge.\n'
    } > "$reprompt_out"

    # Write/update state file.
    {
        printf '{"iteration":%d,"max_iterations":%d,"last_exit_code":%d,"last_reason":"%s"}\n' \
            "$iter" "$max_iters" "$rc" "$reason"
    } > "$state_file"

    echo "validate-and-reprompt: artifact written to $reprompt_out (iteration $iter/$max_iters); exit 5 (retry requested)" >&2
    exit 5
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
