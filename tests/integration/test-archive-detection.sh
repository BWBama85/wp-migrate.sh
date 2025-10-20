#!/usr/bin/env bash
set -Eeuo pipefail

# -------------------------------------------------------------------
# Integration Test: Archive Format Detection
# -------------------------------------------------------------------
# Tests that each minimal test archive is correctly detected by its adapter
# Uses the script's --verbose output to verify format detection

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PROJECT_ROOT/wp-migrate.sh"
FIXTURES="$PROJECT_ROOT/tests/fixtures"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() {
  ((TESTS_PASSED++)) || true
  ((TESTS_RUN++)) || true
  printf "${GREEN}✓${NC} %s\n" "$1"
}

fail() {
  ((TESTS_FAILED++)) || true
  ((TESTS_RUN++)) || true
  printf "${RED}✗${NC} %s\n" "$1"
  [[ -n "${2:-}" ]] && printf "  Error: %s\n" "$2"
}

test_header() {
  printf "\n${YELLOW}%s${NC}\n" "$1"
}

# -------------------------------------------------------------------
# Test: Duplicator format detection
# -------------------------------------------------------------------
test_header "Test: Duplicator archive format detection"

# Run the script with --verbose to capture detection output
# The script will fail because we're not in a WordPress directory, but that's OK
# We just need to see if it detected the format
output=$("$SCRIPT" --archive "$FIXTURES/duplicator-minimal.zip" --verbose 2>&1 || true)

if echo "$output" | grep -qi "duplicator"; then
  pass "Duplicator format detected in verbose output"
else
  fail "Duplicator format not detected" "Expected 'duplicator' in output"
fi

# -------------------------------------------------------------------
# Test: Jetpack format detection
# -------------------------------------------------------------------
test_header "Test: Jetpack archive format detection"

output=$("$SCRIPT" --archive "$FIXTURES/jetpack-minimal.tar.gz" --verbose 2>&1 || true)

if echo "$output" | grep -qi "jetpack"; then
  pass "Jetpack format detected in verbose output"
else
  fail "Jetpack format not detected" "Expected 'jetpack' in output"
fi

# -------------------------------------------------------------------
# Test: Solid Backups format detection
# -------------------------------------------------------------------
test_header "Test: Solid Backups archive format detection"

output=$("$SCRIPT" --archive "$FIXTURES/solidbackups-minimal.zip" --verbose 2>&1 || true)

if echo "$output" | grep -qi "solid"; then
  pass "Solid Backups format detected in verbose output"
else
  fail "Solid Backups format not detected" "Expected 'solid' in output"
fi

# -------------------------------------------------------------------
# Test: Invalid archive rejection
# -------------------------------------------------------------------
test_header "Test: Invalid archive rejection"

# Create a fake archive
FAKE_ARCHIVE="/tmp/fake-archive-$$.zip"
echo "fake data" > "$FAKE_ARCHIVE"

# The script should exit with non-zero status for invalid archive
set +e
"$SCRIPT" --archive "$FAKE_ARCHIVE" >/dev/null 2>&1
exitcode=$?
set -e

# Should fail (non-zero exit code)
if [[ $exitcode -ne 0 ]]; then
  pass "Invalid archive correctly rejected (exit code $exitcode)"
else
  fail "Invalid archive not rejected" "Expected non-zero exit code, got $exitcode"
fi

rm -f "$FAKE_ARCHIVE"

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $TESTS_FAILED -eq 0 ]]; then
  echo "Test Summary: $TESTS_RUN run, ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
else
  echo "Test Summary: $TESTS_RUN run, ${GREEN}$TESTS_PASSED passed${NC}, ${RED}$TESTS_FAILED failed${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi
