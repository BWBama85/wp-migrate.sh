#!/usr/bin/env bash
set -Eeuo pipefail

# -------------------------------------------------------------------
# Integration Test: Zip Slip Path Traversal Protection
# -------------------------------------------------------------------
# End-to-end tests that call the actual validate_archive_paths function
# from the production script on real test archives.
#
# Tests that path traversal attempts are blocked while legitimate
# filenames containing ".." (like "Jr..jpg") are allowed.

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
# Source production code to get validate_archive_paths function
# -------------------------------------------------------------------
# We need to source just enough of the script to get the function
# without triggering main() execution

# Create stub functions for dependencies (called by extracted production code)
# shellcheck disable=SC2329
log_verbose() { :; }
# shellcheck disable=SC2329
log_warning() { :; }
# shellcheck disable=SC2329
err() { echo "ERROR: $*" >&2; return 1; }

# Extract validate_archive_paths function from the built script
# shellcheck source=/dev/null
eval "$(sed -n '/^validate_archive_paths()/,/^}/p' "$SCRIPT")"

# Verify we have the function
if ! declare -f validate_archive_paths > /dev/null 2>&1; then
  echo "FATAL: Could not extract validate_archive_paths from $SCRIPT"
  exit 1
fi

# -------------------------------------------------------------------
# Helper: Create test zip with specific path entries using Python
# -------------------------------------------------------------------
# We use Python's zipfile module because it allows creating entries
# with arbitrary paths that standard zip tools would reject/sanitize
create_malicious_zip() {
  local zip_path="$1"
  shift
  local entries=("$@")

  python3 - "$zip_path" "${entries[@]}" << 'PYTHON_SCRIPT'
import sys
import zipfile

zip_path = sys.argv[1]
entries = sys.argv[2:]

with zipfile.ZipFile(zip_path, 'w') as zf:
    for entry in entries:
        # Write a minimal file for each entry path
        zf.writestr(entry, "test content\n")
PYTHON_SCRIPT
}

# -------------------------------------------------------------------
# Helper: Create test tar.gz with specific path entries
# -------------------------------------------------------------------
create_malicious_tar() {
  local tar_path="$1"
  shift
  local entries=("$@")

  python3 - "$tar_path" "${entries[@]}" << 'PYTHON_SCRIPT'
import sys
import tarfile
import io

tar_path = sys.argv[1]
entries = sys.argv[2:]

with tarfile.open(tar_path, 'w:gz') as tf:
    for entry in entries:
        # Create a TarInfo with the exact path we want
        info = tarfile.TarInfo(name=entry)
        content = b"test content\n"
        info.size = len(content)
        tf.addfile(info, io.BytesIO(content))
PYTHON_SCRIPT
}

# -------------------------------------------------------------------
# Helper: Create uncompressed test .tar with specific path entries
# -------------------------------------------------------------------
create_malicious_plain_tar() {
  local tar_path="$1"
  shift
  local entries=("$@")

  python3 - "$tar_path" "${entries[@]}" << 'PYTHON_SCRIPT'
import sys
import tarfile
import io

tar_path = sys.argv[1]
entries = sys.argv[2:]

# 'w' mode creates uncompressed tar (not 'w:gz')
with tarfile.open(tar_path, 'w') as tf:
    for entry in entries:
        # Create a TarInfo with the exact path we want
        info = tarfile.TarInfo(name=entry)
        content = b"test content\n"
        info.size = len(content)
        tf.addfile(info, io.BytesIO(content))
PYTHON_SCRIPT
}

# -------------------------------------------------------------------
# Test: Legitimate filenames with double periods should be ALLOWED
# -------------------------------------------------------------------
test_header "Test: Legitimate double-period filenames (Jr..jpg, Sr..png)"

SAFE_ZIP="$TEMP_DIR/safe-double-period.zip"
create_malicious_zip "$SAFE_ZIP" \
  "wp-content/uploads/John-Smith-Jr..jpg" \
  "wp-content/uploads/Mary-Jones-Sr..png" \
  "wp-content/uploads/Robert-H.-Turner-Jr..jpeg" \
  "wp-content/uploads/file..with..dots.txt" \
  "wp-content/uploads/normal-file.jpg"

if validate_archive_paths "$SAFE_ZIP"; then
  pass "ZIP: Legitimate double-period filenames allowed"
else
  fail "ZIP: False positive - legitimate filenames incorrectly blocked"
fi

SAFE_TAR="$TEMP_DIR/safe-double-period.tar.gz"
create_malicious_tar "$SAFE_TAR" \
  "wp-content/uploads/John-Smith-Jr..jpg" \
  "wp-content/uploads/Mary-Jones-Sr..png" \
  "wp-content/uploads/normal-file.jpg"

if validate_archive_paths "$SAFE_TAR"; then
  pass "TAR: Legitimate double-period filenames allowed"
else
  fail "TAR: False positive - legitimate filenames incorrectly blocked"
fi

# -------------------------------------------------------------------
# Test: Unix path traversal (../) should be BLOCKED
# -------------------------------------------------------------------
test_header "Test: Unix path traversal (../) blocked"

# Test ../etc/passwd (starts with ../)
MALICIOUS_ZIP="$TEMP_DIR/unix-traversal-start.zip"
create_malicious_zip "$MALICIOUS_ZIP" \
  "../etc/passwd" \
  "safe-file.txt"

if ! validate_archive_paths "$MALICIOUS_ZIP"; then
  pass "ZIP: Blocks ../etc/passwd"
else
  fail "ZIP: Should block ../etc/passwd"
fi

# Test foo/../../../etc/passwd (contains /../)
MALICIOUS_ZIP="$TEMP_DIR/unix-traversal-mid.zip"
create_malicious_zip "$MALICIOUS_ZIP" \
  "foo/../../../etc/passwd"

if ! validate_archive_paths "$MALICIOUS_ZIP"; then
  pass "ZIP: Blocks foo/../../../etc/passwd"
else
  fail "ZIP: Should block foo/../../../etc/passwd"
fi

# Test foo/.. (ends with /..)
MALICIOUS_ZIP="$TEMP_DIR/unix-traversal-end.zip"
create_malicious_zip "$MALICIOUS_ZIP" \
  "foo/.."

if ! validate_archive_paths "$MALICIOUS_ZIP"; then
  pass "ZIP: Blocks foo/.."
else
  fail "ZIP: Should block foo/.."
fi

# Test bare .. entry
MALICIOUS_ZIP="$TEMP_DIR/unix-traversal-bare.zip"
create_malicious_zip "$MALICIOUS_ZIP" \
  ".."

if ! validate_archive_paths "$MALICIOUS_ZIP"; then
  pass "ZIP: Blocks bare .."
else
  fail "ZIP: Should block bare .."
fi

# Same tests for TAR
MALICIOUS_TAR="$TEMP_DIR/unix-traversal.tar.gz"
create_malicious_tar "$MALICIOUS_TAR" \
  "../etc/passwd"

if ! validate_archive_paths "$MALICIOUS_TAR"; then
  pass "TAR: Blocks ../etc/passwd"
else
  fail "TAR: Should block ../etc/passwd"
fi

MALICIOUS_TAR="$TEMP_DIR/unix-traversal-mid.tar.gz"
create_malicious_tar "$MALICIOUS_TAR" \
  "wp-content/../../../etc/passwd"

if ! validate_archive_paths "$MALICIOUS_TAR"; then
  pass "TAR: Blocks wp-content/../../../etc/passwd"
else
  fail "TAR: Should block wp-content/../../../etc/passwd"
fi

# -------------------------------------------------------------------
# Test: Windows path traversal (..\) should be BLOCKED
# -------------------------------------------------------------------
test_header "Test: Windows path traversal (..\\\) blocked"

# Test ..\evil.php (starts with ..\)
MALICIOUS_ZIP="$TEMP_DIR/win-traversal-start.zip"
create_malicious_zip "$MALICIOUS_ZIP" \
  '..\\evil.php'

if ! validate_archive_paths "$MALICIOUS_ZIP"; then
  pass 'ZIP: Blocks ..\\evil.php'
else
  fail 'ZIP: Should block ..\\evil.php'
fi

# Test foo\..\..\..\evil.php (contains \..\)
MALICIOUS_ZIP="$TEMP_DIR/win-traversal-mid.zip"
create_malicious_zip "$MALICIOUS_ZIP" \
  'foo\\..\\..\\evil.php'

if ! validate_archive_paths "$MALICIOUS_ZIP"; then
  pass 'ZIP: Blocks foo\\..\\..\\evil.php'
else
  fail 'ZIP: Should block foo\\..\\..\\evil.php'
fi

# Test foo\.. (ends with \..)
MALICIOUS_ZIP="$TEMP_DIR/win-traversal-end.zip"
create_malicious_zip "$MALICIOUS_ZIP" \
  'foo\\..'

if ! validate_archive_paths "$MALICIOUS_ZIP"; then
  pass 'ZIP: Blocks foo\\..'
else
  fail 'ZIP: Should block foo\\..'
fi

# -------------------------------------------------------------------
# Test: Absolute paths should be BLOCKED
# -------------------------------------------------------------------
test_header "Test: Absolute paths blocked"

# Unix absolute path
MALICIOUS_ZIP="$TEMP_DIR/unix-absolute.zip"
create_malicious_zip "$MALICIOUS_ZIP" \
  "/etc/passwd"

if ! validate_archive_paths "$MALICIOUS_ZIP"; then
  pass "ZIP: Blocks /etc/passwd (Unix absolute)"
else
  fail "ZIP: Should block /etc/passwd"
fi

# Windows absolute path
MALICIOUS_ZIP="$TEMP_DIR/win-absolute.zip"
create_malicious_zip "$MALICIOUS_ZIP" \
  'C:\\Windows\\System32\\config\\SAM'

if ! validate_archive_paths "$MALICIOUS_ZIP"; then
  pass 'ZIP: Blocks C:\\Windows\\... (Windows absolute)'
else
  fail 'ZIP: Should block Windows absolute path'
fi

# TAR with absolute path
MALICIOUS_TAR="$TEMP_DIR/unix-absolute.tar.gz"
create_malicious_tar "$MALICIOUS_TAR" \
  "/etc/passwd"

if ! validate_archive_paths "$MALICIOUS_TAR"; then
  pass "TAR: Blocks /etc/passwd (Unix absolute)"
else
  fail "TAR: Should block /etc/passwd"
fi

# Windows drive with forward slash (C:/)
MALICIOUS_ZIP="$TEMP_DIR/win-forward-slash.zip"
create_malicious_zip "$MALICIOUS_ZIP" \
  'C:/Windows/System32/config/SAM'

if ! validate_archive_paths "$MALICIOUS_ZIP"; then
  pass 'ZIP: Blocks C:/Windows/... (forward slash)'
else
  fail 'ZIP: Should block Windows drive with forward slash'
fi

# UNC path with backslashes (\\server\share)
MALICIOUS_ZIP="$TEMP_DIR/unc-backslash.zip"
create_malicious_zip "$MALICIOUS_ZIP" \
  '\\\\server\\share\\file.txt'

if ! validate_archive_paths "$MALICIOUS_ZIP"; then
  pass 'ZIP: Blocks \\\\server\\share (UNC path)'
else
  fail 'ZIP: Should block UNC path'
fi

# -------------------------------------------------------------------
# Test: Plain .tar (uncompressed) validation
# -------------------------------------------------------------------
test_header "Test: Plain .tar (uncompressed) archives"

# Safe files in plain tar
SAFE_PLAIN_TAR="$TEMP_DIR/safe.tar"
create_malicious_plain_tar "$SAFE_PLAIN_TAR" \
  "wp-content/uploads/John-Smith-Jr..jpg" \
  "wp-content/uploads/normal-file.jpg"

if validate_archive_paths "$SAFE_PLAIN_TAR"; then
  pass "Plain TAR: Legitimate filenames allowed"
else
  fail "Plain TAR: False positive on legitimate filenames"
fi

# Path traversal in plain tar
MALICIOUS_PLAIN_TAR="$TEMP_DIR/traversal.tar"
create_malicious_plain_tar "$MALICIOUS_PLAIN_TAR" \
  "../etc/passwd"

if ! validate_archive_paths "$MALICIOUS_PLAIN_TAR"; then
  pass "Plain TAR: Blocks ../etc/passwd"
else
  fail "Plain TAR: Should block path traversal"
fi

# Absolute path in plain tar
MALICIOUS_PLAIN_TAR="$TEMP_DIR/absolute.tar"
create_malicious_plain_tar "$MALICIOUS_PLAIN_TAR" \
  "/etc/passwd"

if ! validate_archive_paths "$MALICIOUS_PLAIN_TAR"; then
  pass "Plain TAR: Blocks /etc/passwd (absolute)"
else
  fail "Plain TAR: Should block absolute path"
fi

# -------------------------------------------------------------------
# Test: Mixed safe and malicious entries - malicious should be caught
# -------------------------------------------------------------------
test_header "Test: Mixed archives (safe + malicious)"

MIXED_ZIP="$TEMP_DIR/mixed.zip"
create_malicious_zip "$MIXED_ZIP" \
  "wp-content/uploads/safe.jpg" \
  "wp-content/uploads/John-Jr..jpg" \
  "../../../etc/passwd" \
  "wp-content/themes/theme.css"

if ! validate_archive_paths "$MIXED_ZIP"; then
  pass "ZIP: Catches malicious entry among safe entries"
else
  fail "ZIP: Should catch ../../../etc/passwd in mixed archive"
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
