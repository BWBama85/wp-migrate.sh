# Plugin Filtering Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Filter WordPress drop-ins and StellarSites managed plugins from plugin preservation logic to eliminate restoration warnings.

**Architecture:** Add helper function `should_exclude_plugin()` that filters at detection time, keeping excluded plugins out of all downstream logic. Track filtered items in arrays for transparent logging.

**Tech Stack:** Bash, wp-cli, ShellCheck

**Related Issues:** #72 (drop-ins), #73 (StellarSites managed plugins)

**Design Document:** docs/plans/2025-11-13-plugin-filtering-design.md

---

## Task 1: Add Tracking Arrays

**Files:**
- Modify: `src/header.sh:70` (after UNIQUE_DEST_THEMES array)

**Step 1: Add tracking array declarations**

Add these lines after line 70 in `src/header.sh`:

```bash
FILTERED_DROPINS=()         # Drop-ins filtered from plugin preservation
FILTERED_MANAGED_PLUGINS=() # Managed plugins filtered in StellarSites mode
```

**Context:** Line 70 contains `UNIQUE_DEST_THEMES=()`. Add the new arrays immediately after this line.

**Step 2: Verify file structure**

Run: `grep -A 2 "UNIQUE_DEST_THEMES" src/header.sh`

Expected output should show:
```
UNIQUE_DEST_THEMES=()       # Themes unique to destination (to be restored)
FILTERED_DROPINS=()         # Drop-ins filtered from plugin preservation
FILTERED_MANAGED_PLUGINS=() # Managed plugins filtered in StellarSites mode
```

**Step 3: Commit**

```bash
git add src/header.sh
git commit -m "feat: add tracking arrays for filtered plugins

Add FILTERED_DROPINS and FILTERED_MANAGED_PLUGINS arrays to track
what gets excluded during plugin detection.

Related to #72, #73"
```

---

## Task 2: Create Helper Function

**Files:**
- Modify: `src/lib/functions.sh:1047` (add before detect_dest_plugins_push function)

**Step 1: Add should_exclude_plugin function**

Insert this function before line 1047 (before the `detect_dest_plugins_push()` function):

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

**Context:** This function will be called by both `detect_dest_plugins_push()` and `detect_dest_plugins_local()` to determine if a plugin should be excluded.

**Step 2: Verify function location**

Run: `grep -B 2 "detect_dest_plugins_push" src/lib/functions.sh | head -5`

Expected: Should show the new `should_exclude_plugin()` function above the `detect_dest_plugins_push()` comment.

**Step 3: Commit**

```bash
git add src/lib/functions.sh
git commit -m "feat: add should_exclude_plugin helper function

Creates filtering logic for WordPress drop-ins and StellarSites
managed plugins. Populates tracking arrays for logging.

Drop-ins filtered: advanced-cache.php, db.php, db-error.php
Managed plugins filtered (--stellarsites only): stellarsites-cloud

Related to #72, #73"
```

---

## Task 3: Update detect_dest_plugins_push Function

**Files:**
- Modify: `src/lib/functions.sh:1048-1063` (detect_dest_plugins_push function)

**Step 1: Find current implementation**

Run: `sed -n '1048,1063p' src/lib/functions.sh`

You should see the current while loop at lines 1059-1061:
```bash
while IFS= read -r plugin; do
  [[ -n "$plugin" ]] && DEST_PLUGINS_BEFORE+=("$plugin")
done < <(echo "$plugins_csv" | tr ',' '\n')
```

**Step 2: Update the function**

Replace lines 1056-1062 with:

```bash
  local plugins_csv plugin
  plugins_csv=$(wp_remote "$host" "$root" plugin list --field=name --format=csv 2>/dev/null || echo "")
  if [[ -n "$plugins_csv" ]]; then
    # Clear filtering tracking arrays
    FILTERED_DROPINS=()
    FILTERED_MANAGED_PLUGINS=()

    DEST_PLUGINS_BEFORE=()
    while IFS= read -r plugin; do
      if [[ -n "$plugin" ]] && ! should_exclude_plugin "$plugin"; then
        DEST_PLUGINS_BEFORE+=("$plugin")
      fi
    done < <(echo "$plugins_csv" | tr ',' '\n')
  fi
```

**Context:** The key changes are:
1. Clear tracking arrays before loop (lines after `if [[ -n "$plugins_csv" ]]; then`)
2. Add `&& ! should_exclude_plugin "$plugin"` condition in while loop

**Step 3: Verify the change**

Run: `sed -n '1056,1066p' src/lib/functions.sh`

Expected: Should show the updated code with tracking array clearing and the new condition.

**Step 4: Commit**

```bash
git add src/lib/functions.sh
git commit -m "feat: integrate filtering into detect_dest_plugins_push

Call should_exclude_plugin() during push mode plugin detection.
Clears tracking arrays and filters excluded plugins from
DEST_PLUGINS_BEFORE array.

Related to #72, #73"
```

---

## Task 4: Update detect_dest_plugins_local Function

**Files:**
- Modify: `src/lib/functions.sh:1118-1132` (detect_dest_plugins_local function)

**Step 1: Find current implementation**

Run: `sed -n '1118,1132p' src/lib/functions.sh`

You should see the current while loop at lines 1128-1130:
```bash
while IFS= read -r plugin; do
  [[ -n "$plugin" ]] && DEST_PLUGINS_BEFORE+=("$plugin")
done < <(echo "$plugins_csv" | tr ',' '\n')
```

**Step 2: Update the function**

Replace lines 1125-1131 with:

```bash
  local plugins_csv plugin
  plugins_csv=$(wp_local plugin list --field=name --format=csv 2>/dev/null || echo "")
  if [[ -n "$plugins_csv" ]]; then
    # Clear filtering tracking arrays
    FILTERED_DROPINS=()
    FILTERED_MANAGED_PLUGINS=()

    DEST_PLUGINS_BEFORE=()
    while IFS= read -r plugin; do
      if [[ -n "$plugin" ]] && ! should_exclude_plugin "$plugin"; then
        DEST_PLUGINS_BEFORE+=("$plugin")
      fi
    done < <(echo "$plugins_csv" | tr ',' '\n')
  fi
```

**Context:** Identical changes to Task 3, but for the local (archive mode) detection function.

**Step 3: Verify the change**

Run: `sed -n '1125,1135p' src/lib/functions.sh`

Expected: Should show the updated code with tracking array clearing and the new condition.

**Step 4: Commit**

```bash
git add src/lib/functions.sh
git commit -m "feat: integrate filtering into detect_dest_plugins_local

Call should_exclude_plugin() during archive mode plugin detection.
Clears tracking arrays and filters excluded plugins from
DEST_PLUGINS_BEFORE array.

Related to #72, #73"
```

---

## Task 5: Add Push Mode Logging

**Files:**
- Modify: `src/main.sh` (after detect_dest_plugins_push call, around line 610-620)

**Step 1: Find the detection call location**

Run: `grep -n "detect_dest_plugins_push" src/main.sh`

Expected output will show the line number where this function is called.

**Step 2: Find exact insertion point**

Run: `grep -A 10 "detect_dest_plugins_push" src/main.sh | head -15`

This will show you the context after the function call. You need to insert the logging immediately after the function call completes.

**Step 3: Add logging code**

Add these lines immediately after the `detect_dest_plugins_push` call:

```bash
  # Log filtered plugins
  if [[ ${#FILTERED_DROPINS[@]} -gt 0 ]]; then
    log "Filtered drop-ins from preservation: ${FILTERED_DROPINS[*]}"
  fi

  if [[ ${#FILTERED_MANAGED_PLUGINS[@]} -gt 0 ]]; then
    log "Filtered managed plugins from preservation: ${FILTERED_MANAGED_PLUGINS[*]}"
  fi
```

**Context:** This logs what was filtered during push mode detection. The arrays were populated by the `should_exclude_plugin()` function.

**Step 4: Verify insertion**

Run: `grep -A 15 "detect_dest_plugins_push" src/main.sh | head -20`

Expected: Should show the function call followed by the filtering log messages.

**Step 5: Commit**

```bash
git add src/main.sh
git commit -m "feat: add push mode filtering logs

Log filtered drop-ins and managed plugins after push mode
plugin detection. Provides transparency about what was excluded.

Related to #72, #73"
```

---

## Task 6: Add Archive Mode Logging

**Files:**
- Modify: `src/main.sh` (after detect_dest_plugins_local call, around line 1120-1130)

**Step 1: Find the detection call location**

Run: `grep -n "detect_dest_plugins_local" src/main.sh`

Expected output will show the line number where this function is called.

**Step 2: Find exact insertion point**

Run: `grep -A 10 "detect_dest_plugins_local" src/main.sh | head -15`

This will show you the context after the function call.

**Step 3: Add logging code**

Add these lines immediately after the `detect_dest_plugins_local` call:

```bash
  # Log filtered plugins
  if [[ ${#FILTERED_DROPINS[@]} -gt 0 ]]; then
    log "Filtered drop-ins from preservation: ${FILTERED_DROPINS[*]}"
  fi

  if [[ ${#FILTERED_MANAGED_PLUGINS[@]} -gt 0 ]]; then
    log "Filtered managed plugins from preservation: ${FILTERED_MANAGED_PLUGINS[*]}"
  fi
```

**Context:** This logs what was filtered during archive mode detection. Identical to Task 5 but for archive mode.

**Step 4: Verify insertion**

Run: `grep -A 15 "detect_dest_plugins_local" src/main.sh | head -20`

Expected: Should show the function call followed by the filtering log messages.

**Step 5: Commit**

```bash
git add src/main.sh
git commit -m "feat: add archive mode filtering logs

Log filtered drop-ins and managed plugins after archive mode
plugin detection. Provides transparency about what was excluded.

Related to #72, #73"
```

---

## Task 7: Build and Validate

**Files:**
- Build: `wp-migrate.sh` (generated from src/)

**Step 1: Run build process**

Run: `make build`

Expected output:
```
Building temporary file for shellcheck...
Running shellcheck on complete script...
✓ Shellcheck passed
Concatenating source files...
✓ Built dist/wp-migrate.sh
✓ Copied to ./wp-migrate.sh
✓ Generated SHA256 checksum
```

**Context:** The build process concatenates all `src/` files into the final `wp-migrate.sh` script and runs shellcheck validation.

**Step 2: Verify no shellcheck errors**

If shellcheck fails, review the errors and fix them in the `src/` files (not in `wp-migrate.sh`), then run `make build` again.

**Step 3: Verify the built script contains changes**

Run: `grep -A 5 "should_exclude_plugin" wp-migrate.sh | head -10`

Expected: Should show the `should_exclude_plugin()` function in the built script.

**Step 4: Commit built files**

```bash
git add wp-migrate.sh dist/wp-migrate.sh wp-migrate.sh.sha256
git commit -m "build: regenerate wp-migrate.sh with plugin filtering

Rebuilt from source with plugin filtering implementation.
All source changes now reflected in built artifact.

Related to #72, #73"
```

---

## Task 8: Update CHANGELOG

**Files:**
- Modify: `CHANGELOG.md` (add under [Unreleased] section)

**Step 1: Find [Unreleased] section**

Run: `grep -n "\[Unreleased\]" CHANGELOG.md`

Expected: Shows line number of [Unreleased] header.

**Step 2: Add changelog entries**

Under the `### Fixed` or `### Changed` section (create if doesn't exist), add:

```markdown
### Fixed

- Filter WordPress drop-ins (advanced-cache.php, db.php, db-error.php) from plugin preservation logic to prevent restoration failures (#72)
- Filter StellarSites managed plugins (stellarsites-cloud) from preservation in `--stellarsites` mode to prevent restoration warnings (#73)
- Add transparent logging of filtered plugins during migration preview
```

**Context:** If there's no `### Fixed` section under `[Unreleased]`, create it. The entries should describe what was fixed from the user's perspective.

**Step 3: Verify changelog format**

Run: `sed -n '/\[Unreleased\]/,/### /p' CHANGELOG.md | head -20`

Expected: Should show the new entries under the appropriate section.

**Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: update changelog for plugin filtering

Document drop-in and managed plugin filtering improvements.

Related to #72, #73"
```

---

## Task 9: Manual Testing (Dry Run Verification)

**Purpose:** Verify the filtering logic works without running actual migrations.

**Test 1: Verify helper function logic**

Run these commands to test the helper function in isolation:

```bash
# Source the functions
source src/lib/functions.sh
source src/header.sh

# Test drop-in detection
STELLARSITES_MODE=false
should_exclude_plugin "advanced-cache.php" && echo "Correctly excluded drop-in" || echo "ERROR: Should exclude"

# Test normal plugin
should_exclude_plugin "akismet" && echo "ERROR: Should NOT exclude" || echo "Correctly preserved normal plugin"

# Test StellarSites managed plugin without flag
STELLARSITES_MODE=false
should_exclude_plugin "stellarsites-cloud" && echo "ERROR: Should NOT exclude without flag" || echo "Correctly preserved (no flag)"

# Test StellarSites managed plugin with flag
STELLARSITES_MODE=true
should_exclude_plugin "stellarsites-cloud" && echo "Correctly excluded managed plugin" || echo "ERROR: Should exclude with flag"

# Check arrays populated
echo "Filtered drop-ins: ${FILTERED_DROPINS[*]}"
echo "Filtered managed: ${FILTERED_MANAGED_PLUGINS[*]}"
```

Expected output:
```
Correctly excluded drop-in
Correctly preserved normal plugin
Correctly preserved (no flag)
Correctly excluded managed plugin
Filtered drop-ins: advanced-cache.php
Filtered managed: stellarsites-cloud
```

**Test 2: Check built script**

Run: `./wp-migrate.sh --help`

Expected: Should show help output without errors (verifies script is syntactically valid).

**Test 3: Verify logging messages exist**

Run: `grep "Filtered drop-ins from preservation" wp-migrate.sh`

Expected: Should show the logging line appears in the built script.

---

## Testing Notes for Manual Verification

**After this plan is complete**, you should test with actual scenarios:

1. **Test with drop-in present:**
   - Site with `advanced-cache.php` drop-in
   - Run: `./wp-migrate.sh --archive backup.zip --dry-run --verbose`
   - Verify log shows: "Filtered drop-ins from preservation: advanced-cache.php"
   - Verify "Plugins to preserve:" does NOT include advanced-cache.php

2. **Test StellarSites mode:**
   - Site with stellarsites-cloud plugin
   - Run: `./wp-migrate.sh --archive backup.zip --stellarsites --dry-run`
   - Verify log shows: "Filtered managed plugins from preservation: stellarsites-cloud"
   - Verify no restoration warnings for stellarsites-cloud

3. **Test normal plugins still work:**
   - Verify legitimate plugins still appear in preservation list
   - Verify restoration warnings only appear for real issues

---

## Success Criteria

- [ ] All commits follow conventional commit format
- [ ] ShellCheck passes cleanly (`make build` succeeds)
- [ ] Built `wp-migrate.sh` contains all changes
- [ ] CHANGELOG.md updated under [Unreleased]
- [ ] Helper function tests pass (Task 9, Test 1)
- [ ] No shellcheck warnings introduced
- [ ] Git history is clean with descriptive commits

## Execution Notes

- **Required:** Follow TDD where applicable (write test, see fail, implement, see pass)
- **Required:** Commit after each task completes
- **Required:** Run `make build` after modifying `src/` files
- **Required:** Verify shellcheck passes before committing
- **Important:** All modifications go in `src/` files, never edit `wp-migrate.sh` directly

## Related Skills

- @superpowers:executing-plans - Use this to execute this plan
- @superpowers:subagent-driven-development - Alternative execution approach
- @superpowers:verification-before-completion - Use before marking complete
