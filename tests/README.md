# Test Suite for wp-migrate.sh

## Overview

The test suite validates argument parsing, error handling, and code quality without requiring WordPress installations.

## Running Tests

```bash
./test-wp-migrate.sh
```

## Test Coverage

The test suite validates:

1. **Help message** - `--help` displays without errors
2. **WordPress root validation** - Checks for `wp-config.php`
3. **Dependency checking** - Validates required arguments
4. **ShellCheck linting** - Zero errors/warnings
5. **Invalid argument handling** - Rejects unknown flags
6. **SSH option validation** - `--ssh-opt` requires a value
7. **URL override validation** - `--dest-home-url` and `--dest-site-url` require values
8. **Bash syntax** - Script parses without syntax errors
9. **File permissions** - Script is executable

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
