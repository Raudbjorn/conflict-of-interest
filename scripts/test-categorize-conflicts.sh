#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/categorize-conflicts.sh"

passes=0
failures=0

pass() { passes=$((passes + 1)); }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

assert() {
    local description="$1"; shift
    "$@" && pass || fail "$description"
}

assert_not() {
    local description="$1"; shift
    "$@" && fail "$description" || pass
}

assert_eq() {
    local description="$1" expected="$2" actual="$3"
    [ "$expected" = "$actual" ] && pass || fail "$description (expected '$expected', got '$actual')"
}

with_fake_git() {
    local output="$1"; shift
    local tmp old_path
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/fake-git.XXXXXX")"
    cat > "$tmp/git" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2" = "diff --numstat" ]; then
    printf '%b\n' "$output"
    exit 0
fi
exit 1
EOF
    chmod +x "$tmp/git"
    old_path="$PATH"
    PATH="$tmp:$PATH" "$@"
    PATH="$old_path"
    rm -rf "$tmp"
}

test_lockfiles() {
    for file in package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock Cargo.lock poetry.lock uv.lock pdm.lock Gemfile.lock composer.lock mix.lock Package.resolved pubspec.lock packages.lock.json flake.lock; do
        assert "$file is lockfile" is_lockfile "nested/$file"
    done
    assert_not "random.lock is not lockfile" is_lockfile random.lock
    assert_not "package.json is not lockfile" is_lockfile package.json
}

test_migrations() {
    for file in migrations/001_init.py app/migrations/002.py alembic/versions/abc.py src/alembic/versions/abc.py db/migrate/20200101.rb prisma/migrations/20240101000000_init/migration.sql priv/repo/migrations/20240101000000_add.exs src/main/resources/db/changelog/db.changelog.xml db/migration/V1__init.sql sqitch/deploy/add_table.sql sqitch/revert/add_table.sql drizzle/0001_init.sql data-source.ts knexfile.ts; do
        assert "$file is migration" is_migration "$file"
    done
    assert_not "cmd/migrate/main.go is not migration" is_migration cmd/migrate/main.go
    assert_not "alembic/env.py is not migration" is_migration alembic/env.py
}

test_submodule() {
    local repo sha
    repo="$(mktemp -d "${TMPDIR:-/tmp}/submodule-index.XXXXXX")"
    git -C "$repo" init -q
    sha=1111111111111111111111111111111111111111
    (
        cd "$repo"
        printf '160000 %s 1\tdeps/lib\n160000 %s 2\tdeps/lib\n160000 %s 3\tdeps/lib\n' "$sha" "$sha" "$sha" | git update-index --index-info
        assert "mode 160000 unmerged path is submodule" is_submodule deps/lib
        assert_not "ordinary missing path is not submodule" is_submodule src/app.ts
    )
    rm -rf "$repo"
}

test_binary() {
    with_fake_git '-	-	image.png' assert "binary numstat row is binary" is_binary image.png
    with_fake_git '' assert_not "no numstat row is not binary" is_binary notes.txt
    with_fake_git '1	2	notes.txt' assert_not "text numstat row is not binary" is_binary notes.txt
}

test_generated_snapshot_notebook() {
    assert "generated source path" is_generated target/generated-sources/schema.ts
    assert "protobuf generated go" is_generated api/user.pb.go
    assert "GraphQL generated type" is_generated src/schema.graphql.ts
    assert "snapshot directory" is_snapshot src/__snapshots__/view.test.ts.snap
    assert "snap extension" is_snapshot component.snap
    assert "notebook" is_notebook analysis/model.ipynb
    assert_not "markdown is not notebook" is_notebook README.md
}

test_mergiraf() {
    for file in src/main.rs cmd/server.go App.java app.py index.ts App.tsx script.js config.json config.yml config.yaml config.toml config.ini module.sv README.md main.tf Main.hs rules.mk defs.bzl BUILD WORKSPACE CMakeLists.txt go.mod pyproject.toml; do
        assert "$file supported by mergiraf" is_mergiraf_supported "$file"
    done
    assert_not "shell script not mergiraf" is_mergiraf_supported script.sh
    assert_not "plain text not mergiraf" is_mergiraf_supported notes.txt
}

test_category_order() {
    assert_eq "package-lock is lockfile before mergiraf" lockfile "$(categorize_path package-lock.json)"
    assert_eq "migration sql is migration before other" migration "$(categorize_path db/migration/V1__init.sql)"
    assert_eq "snapshot json is snapshot before mergiraf" snapshot "$(categorize_path test.snap.json)"
    assert_eq "notebook category name is consistent" notebook "$(categorize_path notebook.ipynb)"
}

test_lockfiles
test_migrations
test_submodule
test_binary
test_generated_snapshot_notebook
test_mergiraf
test_category_order

echo ""
echo "Results: $passes passed, $failures failed"
[ "$failures" -eq 0 ]

