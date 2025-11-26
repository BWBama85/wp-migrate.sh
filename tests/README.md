# Test Suite for wp-migrate.sh

## Overview

The test suite validates argument parsing, error handling, code quality, and archive format detection without requiring WordPress installations or actual migrations.

## Running Tests

### Unit Tests (Argument Parsing and Validation)
```bash
./test-wp-migrate.sh
```

### Integration Tests (Archive Format Detection)
```bash
./tests/integration/test-archive-detection.sh
```

### Security Tests (Zip Slip Protection)
```bash
./tests/integration/test-zip-slip-protection.sh
```

### All Tests
```bash
make test  # Runs unit tests + shellcheck validation
```

## Test Coverage

### Unit Tests
The unit test suite validates:

1. **Help message** - `--help` displays without errors
2. **WordPress root validation** - Checks for `wp-config.php`
3. **Dependency checking** - Validates required arguments
4. **ShellCheck linting** - Zero errors/warnings
5. **Invalid argument handling** - Rejects unknown flags
6. **SSH option validation** - `--ssh-opt` requires a value
7. **URL override validation** - `--dest-home-url` and `--dest-site-url` require values
8. **Bash syntax** - Script parses without syntax errors
9. **File permissions** - Script is executable

### Integration Tests
The integration test suite validates:

1. **Archive format detection** - Correctly identifies wp-migrate, Duplicator, Jetpack, Solid Backups Legacy, and Solid Backups NextGen formats
2. **Adapter validation** - Each adapter's validation function works correctly
3. **Format signature recognition** - Proper detection of format-specific signature files
4. **Test fixtures** - Minimal test archives for each supported format (see `tests/fixtures/README.md`)

### Security Tests
The Zip Slip protection test suite (`test-zip-slip-protection.sh`) validates:

1. **Legitimate filenames allowed** - Files with `..` in the name (e.g., `John-Smith-Jr..jpg`) are not flagged
2. **Unix path traversal blocked** - Patterns like `../`, `/../`, `/..` are detected and blocked
3. **Windows path traversal blocked** - Patterns like `..\`, `\..\`, `\..` are detected and blocked
4. **Absolute paths blocked** - Both Unix (`/etc/passwd`) and Windows (`C:\`) absolute paths are blocked

### What's NOT Tested
The following scenarios require actual WordPress installations and are tested manually:

- **Actual database migrations** - Real WordPress database imports and exports
- **wp-content transfers** - Real file synchronization operations
- **SSH connections** - Actual remote server operations
- **Live archive extraction** - Full archive extraction (tests use pre-extracted samples)
- **WP-CLI operations** - WordPress installation requirements prevent automated testing
- **URL search-replace** - Requires live WordPress database
- **Rollback operations** - Requires migration artifacts from real migrations

For manual testing procedures, see the relevant GitHub issues or PR descriptions.

## Requirements

- Bash 4.0+
- ShellCheck (optional, but recommended)

## Exit Codes

- `0` - All tests passed
- `1` - One or more tests failed

## Adding New Tests

Add new test cases following this pattern:

```bash
test_header "Test: Description"
output=$($SCRIPT [args] 2>&1 || true)
if echo "$output" | grep -q "expected pattern"; then
  pass "Test description"
else
  fail "Test should do X"
fi
```
