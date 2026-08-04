# Sourced at the end of every suite.
printf '__COUNTS__ %s %s\n' "$NP_TEST_RUN" "$NP_TEST_FAIL"
[ "$NP_TEST_FAIL" -eq 0 ]
