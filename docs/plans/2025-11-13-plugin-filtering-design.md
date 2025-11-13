# Plugin Filtering Design

**Date:** 2025-11-13
**Issues:** #72, #73
**Author:** Design validated through brainstorming session

## Problem Statement

Two types of invalid plugins are appearing in the plugin preservation logic, causing restoration warnings:

1. **WordPress drop-ins** (Issue #72): Files like `advanced-cache.php` are WordPress drop-in files, not plugins. They live in `wp-content/` (not `wp-content/plugins/`) but appear in `wp plugin list` output.

2. **Managed hosting plugins** (Issue #73): In StellarSites environments, plugins like `stellarsites-cloud` are managed by the hosting provider and protected, but still appear in plugin lists.

Both cause restoration failures with warnings like:
```
WARNING: Failed to restore plugin: advanced-cache.php
WARNING: Could not deactivate plugin: advanced-cache.php
```

## Design Goals

1. Filter out WordPress drop-ins from plugin preservation logic
2. Filter out StellarSites managed plugins when `--stellarsites` mode is enabled
3. Log what's being filtered so users understand the behavior
4. Keep the implementation simple and maintainable

## Design Overview

### Approach

Create a single helper function `should_exclude_plugin()` that determines if a plugin should be excluded from preservation. This function will be called by both `detect_dest_plugins_local()` and `detect_dest_plugins_push()` during plugin detection.

**Key decision:** Filter at detection time (not during diff or restoration) to keep excluded plugins out of all downstream logic and logging.

### Filtering Rules

**WordPress Drop-ins (always filtered):**
- `advanced-cache.php` - Used by caching plugins
- `db.php` - Custom database handlers
- `db-error.php` - Custom database error pages

**Note:** Using a focused list of drop-ins that actually appear in real migrations (YAGNI principle), not the complete WordPress drop-in list.

**StellarSites Managed Plugins (filtered only when `--stellarsites` flag is used):**
- `stellarsites-cloud` - The only managed plugin we've observed causing issues

**Note:** Starting with just the one we've seen. Easy to extend when we encounter others.

## Implementation Details

### 1. Helper Function

**Location:** `src/lib/functions.sh` (add before line 1047, before `detect_dest_plugins_push()`)

**Implementation:**
```bash
# Check if a plugin should be excluded from preservation logic
# Returns 0 (true) if should exclude, 1 (false) if should preserve
should_exclude_plugin() {
  local plugin="$1"

  # WordPress drop-ins (not actual plugins)
  local dropins=("advanced-cache.php" "db.php" "db-error.php")
  for dropin in "${dropins[@]}"; do
    if [[ "$plugin" == "$dropin" ]]; then
      FILTERED_DROPINS+=("$plugin")
      return 0
    fi
  done

  # StellarSites managed plugins (when in StellarSites mode)
  if $STELLARSITES_MODE; then
    local managed_plugins=("stellarsites-cloud")
    for managed in "${managed_plugins[@]}"; do
      if [[ "$plugin" == "$managed" ]]; then
        FILTERED_MANAGED_PLUGINS+=("$plugin")
        return 0
      fi
    done
  fi

  return 1  # Don't exclude - preserve this plugin
}
```

**Design notes:**
- Uses local arrays for drop-ins and managed plugins (simple, self-contained)
- Populates tracking arrays (`FILTERED_DROPINS`, `FILTERED_MANAGED_PLUGINS`) for logging
- Returns shell exit codes (0=exclude, 1=keep) for natural bash usage
- Only checks managed plugins when `$STELLARSITES_MODE` is true

### 2. Tracking Arrays

**Location:** `src/header.sh` (add after line 70, after `UNIQUE_DEST_THEMES=()`)

**Declaration:**
```bash
FILTERED_DROPINS=()         # Drop-ins filtered from plugin preservation
FILTERED_MANAGED_PLUGINS=() # Managed plugins filtered in StellarSites mode
```

**Purpose:** Track what was filtered during detection for logging purposes.

### 3. Detection Function Updates

**Functions to modify:**
- `detect_dest_plugins_push()` in `src/lib/functions.sh` (line 1048)
- `detect_dest_plugins_local()` in `src/lib/functions.sh` (line 1118)

**Change in both functions:**

Before:
```bash
while IFS= read -r plugin; do
  [[ -n "$plugin" ]] && DEST_PLUGINS_BEFORE+=("$plugin")
done < <(echo "$plugins_csv" | tr ',' '\n')
```

After:
```bash
# Clear filtering tracking arrays
FILTERED_DROPINS=()
FILTERED_MANAGED_PLUGINS=()

while IFS= read -r plugin; do
  if [[ -n "$plugin" ]] && ! should_exclude_plugin "$plugin"; then
    DEST_PLUGINS_BEFORE+=("$plugin")
  fi
done < <(echo "$plugins_csv" | tr ',' '\n')
```

**Design notes:**
- Clear tracking arrays at start of each detection to ensure accurate per-mode tracking
- Use `! should_exclude_plugin "$plugin"` for natural boolean logic
- Only add to `DEST_PLUGINS_BEFORE` if NOT excluded

### 4. Logging

**Location:** `src/main.sh` - Add logging immediately after each detection function completes

**Push mode location:** After `detect_dest_plugins_push()` call (around line 610-620)

**Archive mode location:** After `detect_dest_plugins_local()` call (around line 1120-1130)

**Logging implementation (add in both locations):**
```bash
# Log filtered plugins
if [[ ${#FILTERED_DROPINS[@]} -gt 0 ]]; then
  log "Filtered drop-ins from preservation: ${FILTERED_DROPINS[*]}"
fi

if [[ ${#FILTERED_MANAGED_PLUGINS[@]} -gt 0 ]]; then
  log "Filtered managed plugins from preservation: ${FILTERED_MANAGED_PLUGINS[*]}"
fi
```

**Design notes:**
- Always log (not just in verbose mode) for transparency
- Only show messages if items were actually filtered (avoid empty logs)
- Uses space-separated list format consistent with other logging

## Testing Strategy

**Note:** As of the fix for issue #75, plugin detection runs in `--dry-run` mode (as a read-only operation), making dry-run testing of filtering behavior valid and recommended.

### Test Scenarios

1. **Drop-in filtering works:**
   - Test site with `advanced-cache.php` drop-in present
   - Run migration with `--dry-run --verbose`
   - Verify drop-in doesn't appear in "Plugins to preserve" list
   - Verify log shows: "Filtered drop-ins from preservation: advanced-cache.php"
   - Verify no restoration warnings appear

2. **StellarSites filtering works:**
   - Migration with `--stellarsites` flag where destination has stellarsites-cloud
   - Verify it's filtered and logged
   - Verify no restoration warnings appear for stellarsites-cloud

3. **Normal plugins still preserved:**
   - Ensure legitimate plugins still appear in preservation list
   - Verify restoration still works for non-excluded plugins

4. **StellarSites mode OFF:**
   - Run without `--stellarsites` flag
   - Verify managed plugins are NOT filtered (only drop-ins)

5. **Edge cases:**
   - Empty plugin list (no plugins installed)
   - Only excluded plugins (all filtered out, arrays empty)
   - Mix of excluded and normal plugins

### Manual Verification

Using the actual migration output from the original issue report:
- Should see filtered logging appear
- Should NOT see restoration warnings for `advanced-cache.php`
- Should NOT see restoration warnings for `stellarsites-cloud`

### Build Validation

```bash
make build    # Should complete without errors
shellcheck wp-migrate.sh  # Should pass cleanly
```

## Expected Behavior After Implementation

### Before (Current):
```
Plugins to preserve: postmark-approved-wordpress-plugin ... stellarsites-cloud advanced-cache.php
  Restoring plugin: stellarsites-cloud
WARNING: Failed to restore plugin: stellarsites-cloud
  Restoring plugin: advanced-cache.php
WARNING: Failed to restore plugin: advanced-cache.php
WARNING: Could not deactivate plugin: advanced-cache.php
```

### After (With Fix):
```
Filtered drop-ins from preservation: advanced-cache.php
Filtered managed plugins from preservation: stellarsites-cloud
Plugins to preserve: postmark-approved-wordpress-plugin ... [other legitimate plugins]
  Restoring plugin: postmark-approved-wordpress-plugin
  [restoration succeeds for legitimate plugins]
```

## Future Extensibility

The design makes it easy to extend:

**Adding more drop-ins:**
```bash
local dropins=("advanced-cache.php" "db.php" "db-error.php" "sunrise.php")
```

**Adding more managed plugins:**
```bash
local managed_plugins=("stellarsites-cloud" "nexcess-mapps" "kinsta-mu-plugins")
```

**Supporting other managed hosting providers:**
Could add similar arrays for other hosting modes if needed in the future.

## Files Modified

1. `src/header.sh` - Add tracking arrays
2. `src/lib/functions.sh` - Add `should_exclude_plugin()` helper
3. `src/lib/functions.sh` - Update `detect_dest_plugins_push()`
4. `src/lib/functions.sh` - Update `detect_dest_plugins_local()`
5. `src/main.sh` - Add logging after push mode detection
6. `src/main.sh` - Add logging after archive mode detection

## Success Criteria

- [ ] No restoration warnings for WordPress drop-ins
- [ ] No restoration warnings for stellarsites-cloud in `--stellarsites` mode
- [ ] Clear logging shows what was filtered and why
- [ ] Legitimate plugins still preserved correctly
- [ ] ShellCheck passes cleanly
- [ ] All edge cases handled properly
