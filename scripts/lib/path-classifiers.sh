#!/usr/bin/env bash

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
        migrations/*|*/migrations/*|alembic/versions/*|*/alembic/versions/*|db/migrate/*|*/db/migrate/*|prisma/migrations/*|*/prisma/migrations/*|priv/repo/migrations/*|*/priv/repo/migrations/*|src/main/resources/db/changelog/*|*/src/main/resources/db/changelog/*|db/changelog/*|*/db/changelog/*|db/migration/*|*/db/migration/*|sqitch/deploy/*|*/sqitch/deploy/*|sqitch/revert/*|*/sqitch/revert/*|drizzle/*|*/drizzle/*)
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

is_test_path() {
    local lower
    lower="$(lower_path "$1")"
    case "$lower" in
        tests/*|*/tests/*|test/*|*/test/*|spec/*|*/spec/*|*/__tests__/*) return 0 ;;
        *_test.*|*.test.*|*.spec.*|*_spec.rb) return 0 ;;
        *) return 1 ;;
    esac
}

is_config_path() {
    local lower name
    lower="$(lower_path "$1")"
    name="$(basename_of "$1")"
    case "$lower" in
        *.json|*.yml|*.yaml|*.toml|*.ini|*.cfg|*.conf|*.properties|*.env|*.config.js|*.config.ts|*.config.mjs) return 0 ;;
    esac
    case "$name" in
        .env*|Dockerfile|.dockerignore|.gitignore|.editorconfig) return 0 ;;
    esac
    return 1
}

is_ui_path() {
    local lower
    lower="$(lower_path "$1")"
    case "$lower" in
        *.css|*.scss|*.sass|*.less|*.svg|*.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.html|*.vue|*.svelte) return 0 ;;
    esac
    case "$lower" in
        components/*|*/components/*|views/*|*/views/*|pages/*|*/pages/*|ui/*|*/ui/*)
            case "$lower" in
                *.ts|*.tsx|*.js|*.jsx|*.mjs) return 0 ;;
            esac ;;
    esac
    return 1
}

is_doc_path() {
    local lower name
    lower="$(lower_path "$1")"
    name="$(basename_of "$lower")"
    case "$lower" in
        docs/*|*/docs/*|references/*|*.md|*.rst|*.txt|*.adoc) return 0 ;;
    esac
    case "$name" in
        readme|readme.*|changelog|changelog.*|license|license.*|notice|notice.*)
            return 0 ;;
    esac
    return 1
}
