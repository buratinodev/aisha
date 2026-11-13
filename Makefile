.PHONY: all check test

all: check test

# Lint (policy in .shellcheckrc)
check:
	shellcheck aisha.sh

# Run the bats suite (llm CLI is stubbed in tests/stubs)
test:
	bats tests
