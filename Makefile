INSTALL_DIR ?= $(HOME)/.claude/skills/git-conflict-resolver
PACKAGE_NAME ?= git-conflict-resolver

.PHONY: test install install-copy package

test:
	@scripts/run-tests.sh

install:
	mkdir -p "$(dir $(INSTALL_DIR))"
	ln -snf "$(CURDIR)" "$(INSTALL_DIR)"

install-copy:
	mkdir -p "$(INSTALL_DIR)"
	rsync -a --delete --exclude='.git' --exclude='.github' --exclude='*.tar.gz' ./ "$(INSTALL_DIR)/"

package:
	tar czf "$(PACKAGE_NAME).tar.gz" \
		--exclude='.git' \
		--exclude='.github' \
		--exclude='*.tar.gz' \
		--transform 's,^,$(PACKAGE_NAME)/,' \
		SKILL.md constitution.md references scripts docs README.md LICENSE NOTICE CHANGELOG.md
