#!/bin/sh
set -u
. "$ROOT/test/lib/assert.sh"
. "$ROOT/nptrace.sh"

assert_match "$NP_TRACE_VERSION" '[0-9]*.[0-9]*.[0-9]*' 'version is semver-shaped'

. "$ROOT/test/lib/report.sh"
