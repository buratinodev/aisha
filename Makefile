.PHONY: all check test

all: check test

# Lint: shellcheck for the shim (policy in .shellcheckrc), compile check for
# the Python core
check:
	shellcheck aisha.sh install.sh
	python3 -m py_compile aisha_core.py

# Run the bats suite (llm CLI is stubbed in tests/stubs)
test:
	bats tests
