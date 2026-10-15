#!/usr/bin/env bash
cd "$(dirname "$0")/.." || exit 1
exe_tests() {
  AGENTICA_TEST_EXECUTABLE="$PWD/dist/agentica" "${MAKE:-make}" --no-print-directory test \
    TESTS="tests/test_process.py tests/modules-test.rkt" JOBS=2
}
if [ "${1:-}" = exe ]; then
  exe_tests
  exit
fi
log="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/executable-tests.log"
exe_tests > "$log" 2>&1 &
executable_tests=$!
status=0
"${MAKE:-make}" --no-print-directory test JOBS=6 || status=$?
if wait "$executable_tests"; then
  echo "::group::process and module tests on the built executable: passed"
else
  echo "::error::the process and module tests failed on the built executable"
  status=1
  echo "::group::process and module tests on the built executable: failed"
fi
cat "$log"
echo "::endgroup::"
exit "$status"
