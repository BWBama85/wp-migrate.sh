#!/usr/bin/env bash
set -Eeuo pipefail

# -------------------------------------------------------------------
# Test suite for wp-migrate.sh
# -------------------------------------------------------------------
# Tests argument parsing, validation, and dry-run safety
# Does NOT require WordPress installations (uses --dry-run mode)

SCRIPT="./wp-migrate.sh"
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
# Test: Help message
# -------------------------------------------------------------------
test_header "Test: Help message displays"
if $SCRIPT --help >/dev/null 2>&1; then
  pass "Help message displays without error"
else
  fail "Help message failed"
fi

# -------------------------------------------------------------------
# Test: Missing required arguments
# -------------------------------------------------------------------
test_header "Test: Missing required arguments"
output=$($SCRIPT 2>&1 || true)
# Script should check for missing mode first (before wp-config.php check)
if echo "$output" | grep -q "No migration mode specified"; then
  pass "Validates migration mode is specified"
else
  fail "Should check for migration mode" "$output"
fi

# Test that wp-config.php check comes after mode check
touch wp-config.php.test-temp
output=$($SCRIPT --duplicator-archive /fake.zip 2>&1 || true)
rm -f wp-config.php.test-temp
if echo "$output" | grep -q "wp-config.php not found"; then
  pass "Validates WordPress root exists"
else
  fail "Should check for wp-config.php" "$output"
fi

# -------------------------------------------------------------------
# Test: Dependency checking
# -------------------------------------------------------------------
test_header "Test: Dependency checking"
# This will fail because we're not in a WP root, but it should check deps first
output=$($SCRIPT --dest-host test@example.com --dest-root /tmp 2>&1 || true)
if echo "$output" | grep -q "wp-config.php not found"; then
  pass "Validates WordPress root before proceeding"
else
  fail "Should validate WordPress root"
fi

# -------------------------------------------------------------------
# Test: ShellCheck linting
# -------------------------------------------------------------------
test_header "Test: ShellCheck linting"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck_output=$(shellcheck "$SCRIPT" 2>&1 || true)
  # Count only errors and warnings, not info notices
  error_count=$(echo "$shellcheck_output" | grep -c "error:" || true)
  warning_count=$(echo "$shellcheck_output" | grep -c "warning:" || true)
  total_issues=$((error_count + warning_count))

  if (( total_issues == 0 )); then
    pass "ShellCheck passes with zero errors/warnings"
  else
    fail "ShellCheck found $total_issues errors/warnings"
  fi
else
  printf "${YELLOW}⊘${NC} ShellCheck not installed, skipping lint test\n"
fi

# -------------------------------------------------------------------
# Test: Invalid arguments
# -------------------------------------------------------------------
test_header "Test: Invalid argument handling"
output=$($SCRIPT --invalid-arg 2>&1 || true)
if echo "$output" | grep -q "Unknown argument"; then
  pass "Rejects invalid arguments"
else
  fail "Should reject invalid arguments"
fi

# -------------------------------------------------------------------
# Test: --ssh-opt validation
# -------------------------------------------------------------------
test_header "Test: SSH option handling"
output=$($SCRIPT --dest-host test@example.com --dest-root /tmp --ssh-opt "" 2>&1 || true)
if echo "$output" | grep -q "requires a value"; then
  pass "Validates --ssh-opt requires a value"
else
  fail "Should validate --ssh-opt has a value"
fi

# -------------------------------------------------------------------
# Test: URL override validation
# -------------------------------------------------------------------
test_header "Test: URL override validation"
output=$($SCRIPT --dest-host test@example.com --dest-root /tmp --dest-home-url "" 2>&1 || true)
if echo "$output" | grep -q "requires a value"; then
  pass "Validates --dest-home-url requires a value"
else
  fail "Should validate --dest-home-url has a value"
fi

output=$($SCRIPT --dest-host test@example.com --dest-root /tmp --dest-site-url "" 2>&1 || true)
if echo "$output" | grep -q "requires a value"; then
  pass "Validates --dest-site-url requires a value"
else
  fail "Should validate --dest-site-url has a value"
fi

# -------------------------------------------------------------------
# Test: Script syntax
# -------------------------------------------------------------------
test_header "Test: Bash syntax validation"
if bash -n "$SCRIPT" 2>/dev/null; then
  pass "Bash syntax is valid"
else
  fail "Bash syntax check failed"
fi

# -------------------------------------------------------------------
# Test: File permissions
# -------------------------------------------------------------------
test_header "Test: Script is executable"
if [[ -x "$SCRIPT" ]]; then
  pass "Script has executable permissions"
else
  fail "Script should be executable"
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
printf "\n"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Test Summary: %d run, ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" \
  "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

if (( TESTS_FAILED > 0 )); then
  exit 1
fi

exit 0
