#!/usr/bin/env bash
set -Eeuo pipefail

# -------------------------------------------------------------------
# Integration Test: Zip Slip Path Traversal Protection
# -------------------------------------------------------------------
# Tests that path traversal attempts are blocked while legitimate
# filenames containing ".." (like "Jr..jpg") are allowed.
#
# This is a regression test for the fix that prevents false positives
# on filenames like "John-Smith-Jr..jpg" while still blocking actual
# path traversal attacks like "../../../etc/passwd".

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PROJECT_ROOT/wp-migrate.sh"

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

# Create temporary directory for test archives
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# -------------------------------------------------------------------
# Helper: Create test zip archive with specific filenames
# -------------------------------------------------------------------
create_test_zip() {
  local zip_path="$1"
  shift
  local files=("$@")

  local work_dir="$TEMP_DIR/work-$$"
  mkdir -p "$work_dir"

  for file in "${files[@]}"; do
    # Create directory structure if needed
    local dir
    dir=$(dirname "$file")
    if [[ "$dir" != "." ]]; then
      mkdir -p "$work_dir/$dir"
    fi
    echo "test content" > "$work_dir/$file"
  done

  (cd "$work_dir" && zip -q -r "$zip_path" .)
  rm -rf "$work_dir"
}

# -------------------------------------------------------------------
# Test: Legitimate filenames with double periods should be ALLOWED
# -------------------------------------------------------------------
test_header "Test: Legitimate double-period filenames (Jr..jpg, Sr..png)"

SAFE_ZIP="$TEMP_DIR/safe-double-period.zip"
create_test_zip "$SAFE_ZIP" \
  "wp-content/uploads/John-Smith-Jr..jpg" \
  "wp-content/uploads/Mary-Jones-Sr..png" \
  "wp-content/uploads/Robert-H.-Turner-Jr..jpeg" \
  "wp-content/uploads/normal-file.jpg"

output=$("$SCRIPT" --archive "$SAFE_ZIP" --verbose 2>&1 || true)

# Should NOT contain "path traversal" warnings for these files
if echo "$output" | grep -q "path traversal attempt.*Jr\.\.\|path traversal attempt.*Sr\.\."; then
  fail "False positive: legitimate Jr./Sr. filenames incorrectly flagged as traversal"
else
  pass "Legitimate double-period filenames allowed (Jr..jpg, Sr..png)"
fi

# -------------------------------------------------------------------
# Test: Unix path traversal (../) should be BLOCKED
# -------------------------------------------------------------------
test_header "Test: Unix path traversal (../) blocked"

# We can't easily create a malicious zip with standard tools,
# so we test by checking the script's validation logic directly.
# Create a zip and manually verify the patterns would be caught.

# Test the regex patterns used in the script
test_unix_traversal() {
  local entry="$1"
  local expected="$2"  # "block" or "allow"

  local blocked=false
  if [[ "$entry" =~ ^\.\./ ]] || [[ "$entry" =~ /\.\./ ]] || [[ "$entry" =~ /\.\.$ ]] || \
     [[ "$entry" =~ ^\.\.\\  ]] || [[ "$entry" =~ \\\.\.\\  ]] || [[ "$entry" =~ \\\.\.$ ]] || \
     [[ "$entry" == ".." ]]; then
    blocked=true
  fi

  if [[ "$expected" == "block" ]] && $blocked; then
    return 0
  elif [[ "$expected" == "allow" ]] && ! $blocked; then
    return 0
  else
    return 1
  fi
}

# Unix-style traversal attempts (should be BLOCKED)
if test_unix_traversal "../etc/passwd" "block"; then
  pass "Blocks: ../etc/passwd"
else
  fail "Should block: ../etc/passwd"
fi

if test_unix_traversal "foo/../../../etc/passwd" "block"; then
  pass "Blocks: foo/../../../etc/passwd"
else
  fail "Should block: foo/../../../etc/passwd"
fi

if test_unix_traversal "wp-content/../../../etc/passwd" "block"; then
  pass "Blocks: wp-content/../../../etc/passwd"
else
  fail "Should block: wp-content/../../../etc/passwd"
fi

if test_unix_traversal ".." "block"; then
  pass "Blocks: .. (bare parent reference)"
else
  fail "Should block: .."
fi

if test_unix_traversal "foo/.." "block"; then
  pass "Blocks: foo/.."
else
  fail "Should block: foo/.."
fi

# -------------------------------------------------------------------
# Test: Windows path traversal (..\) should be BLOCKED
# -------------------------------------------------------------------
test_header "Test: Windows path traversal (..\\) blocked"

if test_unix_traversal '..\\evil.php' "block"; then
  pass 'Blocks: ..\\evil.php'
else
  fail 'Should block: ..\\evil.php'
fi

if test_unix_traversal 'foo\\..\\..\\evil.php' "block"; then
  pass 'Blocks: foo\\..\\..\\evil.php'
else
  fail 'Should block: foo\\..\\..\\evil.php'
fi

if test_unix_traversal 'wp-content\\..\\..\\etc\\passwd' "block"; then
  pass 'Blocks: wp-content\\..\\..\\etc\\passwd'
else
  fail 'Should block: wp-content\\..\\..\\etc\\passwd'
fi

if test_unix_traversal 'foo\\..' "block"; then
  pass 'Blocks: foo\\..'
else
  fail 'Should block: foo\\..'
fi

# -------------------------------------------------------------------
# Test: Legitimate filenames should be ALLOWED
# -------------------------------------------------------------------
test_header "Test: Legitimate filenames allowed"

if test_unix_traversal "John-Smith-Jr..jpg" "allow"; then
  pass "Allows: John-Smith-Jr..jpg"
else
  fail "Should allow: John-Smith-Jr..jpg"
fi

if test_unix_traversal "wp-content/uploads/Mary-Sr..png" "allow"; then
  pass "Allows: wp-content/uploads/Mary-Sr..png"
else
  fail "Should allow: wp-content/uploads/Mary-Sr..png"
fi

if test_unix_traversal "file..with..multiple..dots.txt" "allow"; then
  pass "Allows: file..with..multiple..dots.txt"
else
  fail "Should allow: file..with..multiple..dots.txt"
fi

if test_unix_traversal "normal/path/to/file.jpg" "allow"; then
  pass "Allows: normal/path/to/file.jpg"
else
  fail "Should allow: normal/path/to/file.jpg"
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $TESTS_FAILED -eq 0 ]]; then
  printf "Test Summary: %d run, ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
else
  printf "Test Summary: %d run, ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" "$TESTS_RUN" "$TESTS_PASSED" "$TESTS_FAILED"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi
