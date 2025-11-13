# WP-CLI Skip Flags Design

**Date:** 2025-11-13
**Issue:** #78
**Author:** Design validated through brainstorming session

## Problem Statement

When migrations cause critical PHP errors from plugins or themes, subsequent WP-CLI commands fail because WordPress can't bootstrap. This prevents:
- Rollback operations (can't detect plugins)
- Search-replace operations (can't run wp-cli)
- Any recovery via the script

Currently, `wp_remote()` uses `--skip-plugins --skip-themes` by default (since v2.0.0), but `wp_local()` does not. This creates an inconsistency where remote operations are protected from plugin errors but local operations are not.

## Design Goals

1. Make `wp_local()` consistent with `wp_remote()` behavior
2. Provide automatic recovery from plugin/theme errors
3. Maintain predictable, reliable migration behavior
4. Zero breaking changes (all script commands work without plugins/themes)

## Design Overview

### Approach

Add `--skip-plugins --skip-themes` flags to `wp_local()` function to match existing `wp_remote()` behavior.

**Key Decision:** Skip by default, always. No user override needed because:
- Current `wp_remote()` has worked this way since v2.0.0 without complaints
- All script commands work without plugins/themes (low-level operations)
- Users who need WP-CLI with plugins can use `wp` command directly

## Implementation Details

### Core Change

**File:** `src/lib/functions.sh`
**Location:** Lines 1-4 (wp_local function)

**Current:**
```bash
wp_local() {
  log_trace "wp --path=\"$PWD\" $*"
  wp --path="$PWD" "$@"
}
```

**Updated:**
```bash
wp_local() {
  log_trace "wp --skip-plugins --skip-themes --path=\"$PWD\" $*"
  wp --skip-plugins --skip-themes --path="$PWD" "$@"
}
```

### Why This Works

All WP-CLI commands used by the script are low-level operations that work without plugin/theme code:

**Database Operations:**
- `wp db import/export/reset/check/query` - Direct MySQL operations
- `wp search-replace` - Direct database string replacement
- `wp option get` - Direct wp_options table read

**Filesystem Operations:**
- `wp config create/set` - Modifies wp-config.php file
- `wp plugin list` - Reads plugin directory + database
- `wp theme list` - Reads theme directory + database

**Core Operations:**
- `wp core version/is-installed` - Reads core files
- `wp db prefix/tables` - Database metadata

### Benefits

1. **Automatic Error Recovery**
   - If a plugin causes fatal error, migrations still work
   - Rollback operations succeed even with broken plugins
   - No manual intervention required

2. **Predictable Behavior**
   - No plugin hooks modifying search-replace
   - No theme functions interfering with operations
   - Consistent behavior across all environments

3. **Security**
   - Don't execute potentially untrusted plugin code from archives
   - Safer when importing from unknown sources

4. **Performance**
   - Faster WP-CLI bootstrap without loading plugin code
   - Especially noticeable on sites with many plugins

5. **Cross-Version Compatibility**
   - Don't break when plugins aren't compatible with destination PHP/WP version
   - Archive from PHP 7.4 → PHP 8.2 still works

### Downsides Analysis

**No significant downsides** for this use case because:

✅ All migration commands are low-level operations
✅ Plugin/theme code can interfere with migrations (we WANT to avoid this)
✅ Consistency is critical (same behavior every time)
✅ Current `wp_remote()` proves this approach works (since v2.0.0)

**Theoretical edge cases** (not relevant):
- Custom WP-CLI commands from plugins (script doesn't use any)
- Plugin filters on search-replace (we want clean, unmodified behavior)
- Dynamic table prefix from plugins (extremely unlikely scenario)

## Documentation

### CHANGELOG Entry

```markdown
## [2.9.0] - TBD

### Changed

- **WP-CLI commands now skip plugins/themes by default**: All local WP-CLI operations now use `--skip-plugins --skip-themes` flags (#78)
  - Provides automatic recovery when migrations cause plugin/theme errors
  - Matches existing remote WP-CLI behavior (since v2.0.0)
  - All migration operations work without loading plugin/theme code
  - No functional changes - script uses low-level database/filesystem commands only
```

### Help Text Addition

Add to `print_usage()` function in `src/lib/functions.sh`:

```bash
NOTES:
  - All WP-CLI commands skip loading plugins and themes for reliability
  - This prevents plugin errors from breaking migrations or rollbacks
  - Migration operations use low-level database and filesystem commands
  - If you need WP-CLI with plugins loaded, use 'wp' command directly
```

## Testing Strategy

### Build Validation

```bash
make build
```

**Expected:**
- ShellCheck passes cleanly
- Build completes successfully
- No new warnings or errors

### Functional Validation

```bash
# Test in WordPress installation
./wp-migrate.sh --dry-run --verbose
```

**Expected:**
- All wp_local commands execute successfully
- Commands complete without plugin/theme loading errors
- No change in visible behavior (operations work the same)

### Help Text Validation

```bash
./wp-migrate.sh --help
```

**Expected:**
- New NOTES section appears in help output
- Explains skip behavior clearly

### Real-World Scenario (Optional)

```bash
# Create plugin with fatal error
# Run migration or rollback
```

**Expected:**
- Migration/rollback completes despite plugin error
- No "Fatal error" from plugin during WP-CLI commands

## Expected Behavior

### Before This Change

**Local commands:**
```bash
# wp_local loads plugins/themes
wp plugin list
# If plugin has fatal error → command fails
# Migration/rollback breaks
```

**Remote commands:**
```bash
# wp_remote skips plugins/themes (since v2.0.0)
wp plugin list
# Works even with plugin errors
```

**Result:** Inconsistent behavior between local and remote

### After This Change

**Both local and remote:**
```bash
# Both skip plugins/themes
wp plugin list
# Works even with plugin errors
# Consistent, predictable behavior
```

**Result:** Consistent behavior, automatic error recovery

## Implementation Impact

**Files Modified:**
- `src/lib/functions.sh` - Update `wp_local()` function (2 lines changed)
- `src/lib/functions.sh` - Add NOTES section to help text (~4 lines added)
- `CHANGELOG.md` - Add entry under [Unreleased]
- `wp-migrate.sh` - Rebuilt with changes

**Breaking Changes:**
- None - all commands work without plugins/themes

**User Impact:**
- Positive - automatic error recovery
- Transparent - no visible change in normal operation
- Documented - explained in help text and changelog

## Success Criteria

- [ ] `wp_local()` uses `--skip-plugins --skip-themes`
- [ ] Help text documents this behavior
- [ ] CHANGELOG updated
- [ ] ShellCheck passes
- [ ] Build succeeds
- [ ] No regression in functionality

## Related Issues

- Issue #78 - Enhancement request for skip flags
- v2.0.0 - When `wp_remote()` added skip flags
