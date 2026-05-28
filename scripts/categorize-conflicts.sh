#!/usr/bin/env bash
set -euo pipefail

basename_of() {
    local path="$1"
    printf '%s\n' "${path##*/}"
}

lower_path() {
    local path="$1"
    printf '%s\n' "$path" | tr '[:upper:]' '[:lower:]'
}

is_lockfile() {
    local name
    name="$(basename_of "$1")"
    case "$name" in
        package-lock.json|npm-shrinkwrap.json|yarn.lock|pnpm-lock.yaml|bun.lockb|bun.lock|Cargo.lock|poetry.lock|uv.lock|pdm.lock|Gemfile.lock|composer.lock|mix.lock|Package.resolved|pubspec.lock|packages.lock.json|flake.lock)
            return 0 ;;
        *) return 1 ;;
    esac
}

is_migration() {
    local path lower name
    path="$1"
    lower="$(lower_path "$path")"
    name="$(basename_of "$lower")"

    case "$lower" in
        migrations/*|*/migrations/*|alembic/versions/*|*/alembic/versions/*|db/migrate/*|*/db/migrate/*|prisma/migrations/*|*/prisma/migrations/*|priv/repo/migrations/*|*/priv/repo/migrations/*|src/main/resources/db/changelog/*|*/src/main/resources/db/changelog/*|db/changelog/*|*/db/changelog/*|db/migration/*|*/db/migration/*|sqitch/deploy/*|*/sqitch/deploy/*|sqitch/revert/*|*/sqitch/revert/*|migrations/deploy/*|*/migrations/deploy/*|migrations/revert/*|*/migrations/revert/*|drizzle/*|*/drizzle/*)
            return 0 ;;
        ormconfig.*|data-source.ts|data-source.js|knexfile.*)
            return 0 ;;
    esac

    case "$name" in
        v[0-9]*__*.sql|*.changeset.xml|*.changelog.xml|*.migration.sql|*_migration.sql)
            return 0 ;;
    esac

    return 1
}

is_submodule() {
    local path="$1"
    git ls-files -u -- "$path" 2>/dev/null | awk '$1 == "160000" {found=1} END {exit found ? 0 : 1}'
}

is_binary() {
    local path="$1" numstat
    numstat="$(git diff --numstat -- "$path" 2>/dev/null || true)"
    printf '%s\n' "$numstat" | awk '$1 == "-" && $2 == "-" {found=1} END {exit found ? 0 : 1}'
}

is_generated() {
    local path lower name
    path="$1"
    lower="$(lower_path "$path")"
    name="$(basename_of "$lower")"
    case "$lower" in
        generated/*|*/generated/*|*/generated-sources/*|dist/*|*/dist/*|build/*|*/build/*|coverage/*|*/coverage/*|*.generated.*|*.gen.*|*.g.dart|*.pb.go|*.pb.cc|*.pb.h|*.pb.swift|*.graphql.ts|*.graphql.d.ts)
            return 0 ;;
    esac
    case "$name" in
        schema.graphql|schema.json)
            return 0 ;;
    esac
    return 1
}

is_snapshot() {
    local lower
    lower="$(lower_path "$1")"
    case "$lower" in
        *__snapshots__/*|*.snap|*.snapshot|*.snapshots|*.snap.txt|*.snap.json)
            return 0 ;;
        *) return 1 ;;
    esac
}

is_notebook() {
    case "$(lower_path "$1")" in
        *.ipynb) return 0 ;;
        *) return 1 ;;
    esac
}

is_mergiraf_supported() {
    local path name lower
    path="$1"
    name="$(basename_of "$path")"
    lower="$(lower_path "$path")"
    case "$name" in
        Makefile|GNUmakefile|BUILD|WORKSPACE|CMakeLists.txt|go.mod|go.sum|go.work.sum|pyproject.toml)
            return 0 ;;
    esac
    case "$lower" in
        *.rs|*.go|*.java|*.py|*.ts|*.tsx|*.js|*.jsx|*.json|*.yml|*.yaml|*.toml|*.ini|*.sv|*.svh|*.md|*.hcl|*.tf|*.tfvars|*.ml|*.mli|*.hs|*.mk|*.bzl|*.bazel|*.cmake|*.c|*.cc|*.cpp|*.h|*.hpp|*.kt|*.kts|*.scala|*.rb|*.ex|*.exs)
            return 0 ;;
        *) return 1 ;;
    esac
}

categorize_path() {
    local path="$1"
    if is_submodule "$path"; then
        echo "submodule"
    elif is_binary "$path"; then
        echo "binary"
    elif is_lockfile "$path"; then
        echo "lockfile"
    elif is_migration "$path"; then
        echo "migration"
    elif is_snapshot "$path"; then
        echo "snapshot"
    elif is_notebook "$path"; then
        echo "notebook"
    elif is_generated "$path"; then
        echo "generated"
    elif is_mergiraf_supported "$path"; then
        echo "mergiraf"
    else
        echo "other"
    fi
}

main() {
    command -v git >/dev/null || { echo "ERROR: git not found in PATH" >&2; exit 12; }
    git rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: not in a git repository" >&2; exit 11; }

    local path
    git diff --name-only --diff-filter=U | while IFS= read -r path; do
        [ -n "$path" ] || continue
        printf '%s\t%s\n' "$(categorize_path "$path")" "$path"
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi

