.POSIX:

# The shell the code under test runs in. bats itself needs bash, but the SDK
# must be exercised in the target shell — see test/helper.bash.
NP_TEST_SHELL ?= /bin/sh

build:
	./build.sh

# Only src/ and build.sh are POSIX sh; the .bats suites are bash by definition.
lint:
	find build.sh src -name '*.sh' -type f -print0 | xargs -0 shellcheck -s sh

test: build
	NP_TEST_SHELL=$(NP_TEST_SHELL) bats test/unit

test-all: build
	NP_TEST_SHELL=$(NP_TEST_SHELL) bats test/unit test/integration

# busybox ash is the most limited shell/awk/od combination we support, and the
# likeliest thing a consumer's CI actually runs. alpine gives us both halves:
# /bin/sh IS busybox, and bats+jq are one apk away.
test-busybox:
	docker run --rm -v "$$PWD:/w" -w /w alpine:latest sh -c '\
	  apk add --no-cache bash bats jq >/dev/null && \
	  sh build.sh >/dev/null && \
	  NP_TEST_SHELL=/bin/sh bats test/unit test/integration'

.PHONY: build lint test test-all test-busybox
