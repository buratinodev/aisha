.PHONY: all check test release

all: check test

# Lint: shellcheck for the shim (policy in .shellcheckrc), compile check for
# the Python core
check:
	shellcheck aisha.sh install.sh
	python3 -m py_compile aisha_core.py

# Run the bats suite (llm CLI is stubbed in tests/stubs)
test:
	bats tests

# Tag the current commit as v<VERSION> and push the tag; the Release
# workflow (.github/workflows/release.yml) publishes the GitHub release.
VERSION := $(shell sed -n 's/^VERSION = "\(.*\)"/\1/p' aisha_core.py)
release: check
	@test -n "$(VERSION)" || { echo "VERSION not found in aisha_core.py"; exit 1; }
	@git diff --quiet && git diff --cached --quiet || { echo "Uncommitted changes; commit first."; exit 1; }
	@! git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null || { echo "Tag v$(VERSION) already exists; bump VERSION first."; exit 1; }
	@git fetch -q origin main && test "$$(git rev-parse HEAD)" = "$$(git rev-parse origin/main)" || { echo "HEAD is not origin/main; push first."; exit 1; }
	git tag -a "v$(VERSION)" -m "aisha $(VERSION)"
	git push origin "v$(VERSION)"
