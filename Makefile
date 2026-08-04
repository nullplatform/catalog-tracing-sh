.POSIX:

build:
	./build.sh

lint:
	find build.sh src test -name '*.sh' -type f -print0 | xargs -0 shellcheck -s sh

test: build
	sh test/run.sh unit

test-all: build
	sh test/run.sh all

.PHONY: build lint test test-all
