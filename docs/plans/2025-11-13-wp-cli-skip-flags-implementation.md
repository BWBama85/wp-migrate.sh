# WP-CLI Skip Flags Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make wp_local() consistent with wp_remote() by adding --skip-plugins --skip-themes for automatic error recovery.

**Architecture:** Single-point change in wp_local() function to add skip flags, matching existing wp_remote() behavior from v2.0.0.

**Tech Stack:** Bash, WP-CLI, ShellCheck

**Related Issue:** #78

**Design Document:** docs/plans/2025-11-13-wp-cli-skip-flags-design.md

---

## Task 1: Update wp_local() Function

**Files:**
- Modify: `src/lib/functions.sh:1-4` (wp_local function)

**Step 1: Read current wp_local() implementation**

Run: `sed -n '1,4p' src/lib/functions.sh`

Expected output:
```bash
wp_local() {
  log_trace "wp --path=\"$PWD\" $*"
  wp --path="$PWD" "$@"
}
```

**Step 2: Update wp_local() to add skip flags**

Replace lines 1-4 in `src/lib/functions.sh`:

**Old:**
```bash
wp_local() {
  log_trace "wp --path=\"$PWD\" $*"
  wp --path="$PWD" "$@"
}
```

**New:**
```bash
wp_local() {
  log_trace "wp --skip-plugins --skip-themes --path=\"$PWD\" $*"
  wp --skip-plugins --skip-themes --path="$PWD" "$@"
}
```

**Context:** This makes wp_local() consistent with wp_remote() which already uses these flags (line 635).

**Step 3: Verify the change**

Run: `sed -n '1,4p' src/lib/functions.sh`

Expected output:
```bash
wp_local() {
  log_trace "wp --skip-plugins --skip-themes --path=\"$PWD\" $*"
  wp --skip-plugins --skip-themes --path="$PWD" "$@"
}
```

**Step 4: Commit**

```bash
git add src/lib/functions.sh
git commit -m "feat: add --skip-plugins --skip-themes to wp_local()

Makes wp_local() consistent with wp_remote() for automatic error
recovery when plugins/themes cause fatal errors.

All WP-CLI commands used by the script work without loading
plugin/theme code (low-level database and filesystem operations).

Relates to #78"
```

---

## Task 2: Add NOTES Section to Help Text

**Files:**
- Modify: `src/lib/functions.sh` (print_usage function, around line 1800-1900)

**Step 1: Find the print_usage function**

Run: `grep -n "^print_usage()" src/lib/functions.sh`

Expected output will show the line number where print_usage() starts.

**Step 2: Find the end of the help text**

Run: `grep -n "^USAGE$" src/lib/functions.sh | tail -1`

This will show where to add the NOTES section (after the existing help content).

**Step 3: Locate insertion point**

The NOTES section should be added after the Examples section and before the final "USAGE" marker.

Run: `grep -n "^USAGE$" src/lib/functions.sh`

You'll add the NOTES section just before the final "USAGE" line.

**Step 4: Add NOTES section**

Insert these lines before the final `USAGE` line in the print_usage() function:

```bash
NOTES:
  - All WP-CLI commands skip loading plugins and themes for reliability
  - This prevents plugin errors from breaking migrations or rollbacks
  - Migration operations use low-level database and filesystem commands
  - If you need WP-CLI with plugins loaded, use 'wp' command directly

```

**Context:** This documents the behavior change for users who run `./wp-migrate.sh --help`.

**Step 5: Verify help text appears**

Run: `./wp-migrate.sh --help | grep -A 4 "^NOTES:"`

Expected output:
```
NOTES:
  - All WP-CLI commands skip loading plugins and themes for reliability
  - This prevents plugin errors from breaking migrations or rollbacks
  - Migration operations use low-level database and filesystem commands
  - If you need WP-CLI with plugins loaded, use 'wp' command directly
```

**Note:** The script isn't built yet, so this verification will happen after Task 4 (Build).

**Step 6: Commit**

```bash
git add src/lib/functions.sh
git commit -m "docs: add NOTES section to help text

Explains that WP-CLI commands skip plugins/themes for reliability
and automatic error recovery.

Relates to #78"
```

---

## Task 3: Update CHANGELOG.md

**Files:**
- Modify: `CHANGELOG.md` (add under [Unreleased] section)

**Step 1: Find the [Unreleased] section**

Run: `grep -n "## \[Unreleased\]" CHANGELOG.md`

Expected output will show the line number of the [Unreleased] section.

**Step 2: Add changelog entry**

Under the `## [Unreleased]` section, add a new `### Changed` section (or add to existing one if present):

```markdown
### Changed

- **WP-CLI commands now skip plugins/themes by default**: All local WP-CLI operations now use `--skip-plugins --skip-themes` flags (#78)
  - Provides automatic recovery when migrations cause plugin/theme errors
  - Matches existing remote WP-CLI behavior (since v2.0.0)
  - All migration operations work without loading plugin/theme code
  - No functional changes - script uses low-level database/filesystem commands only
```

**Context:** If a `### Changed` section already exists under `[Unreleased]`, add the entry there. Otherwise, create the section.

**Step 3: Verify changelog format**

Run: `sed -n '/\[Unreleased\]/,/^## /p' CHANGELOG.md | head -20`

Expected: Should show the new entry under the appropriate section.

**Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: update CHANGELOG for WP-CLI skip flags

Document that wp_local() now uses --skip-plugins --skip-themes
to match wp_remote() behavior for automatic error recovery.

Relates to #78"
```

---

## Task 4: Build and Validate

**Files:**
- Build: `wp-migrate.sh` (generated from src/)
- Build: `wp-migrate.sh.sha256` (checksum)

**Step 1: Run build process**

Run: `make build`

Expected output:
```
Building temporary file for shellcheck...
Running shellcheck on complete script...
✓ Shellcheck passed
Building wp-migrate.sh...
✓ Built: dist/wp-migrate.sh
✓ Copied: ./wp-migrate.sh (repo root)
✓ Checksum: wp-migrate.sh.sha256

Build complete! Users can download:
  curl -O https://raw.githubusercontent.com/BWBama85/wp-migrate.sh/main/wp-migrate.sh
```

**Context:** The build process concatenates all src/ files into the final wp-migrate.sh script and runs shellcheck validation.

**Step 2: Verify wp_local() in built script**

Run: `grep -A 3 "^wp_local()" wp-migrate.sh`

Expected output:
```bash
wp_local() {
  log_trace "wp --skip-plugins --skip-themes --path=\"$PWD\" $*"
  wp --skip-plugins --skip-themes --path="$PWD" "$@"
}
```

**Step 3: Verify help text in built script**

Run: `./wp-migrate.sh --help | grep -A 4 "^NOTES:"`

Expected output:
```
NOTES:
  - All WP-CLI commands skip loading plugins and themes for reliability
  - This prevents plugin errors from breaking migrations or rollbacks
  - Migration operations use low-level database and filesystem commands
  - If you need WP-CLI with plugins loaded, use 'wp' command directly
```

**Step 4: Verify shellcheck passes**

Run: `shellcheck wp-migrate.sh`

Expected: No output (clean exit means no warnings or errors).

**Step 5: Commit built files**

```bash
git add wp-migrate.sh wp-migrate.sh.sha256
git commit -m "build: regenerate wp-migrate.sh with WP-CLI skip flags

Rebuilt from source with updated wp_local() function.

Relates to #78"
```

---

## Task 5: Final Verification

**Purpose:** Verify the complete implementation works as expected.

**Step 1: Verify all commits are present**

Run: `git log --oneline -4`

Expected output (order may vary):
```
<hash> build: regenerate wp-migrate.sh with WP-CLI skip flags
<hash> docs: update CHANGELOG for WP-CLI skip flags
<hash> docs: add NOTES section to help text
<hash> feat: add --skip-plugins --skip-themes to wp_local()
```

**Step 2: Verify function consistency**

Compare wp_local() and wp_remote():

Run:
```bash
echo "=== wp_local() ===" && grep -A 3 "^wp_local()" wp-migrate.sh
echo "" && echo "=== wp_remote() ===" && grep -A 5 "^wp_remote()" wp-migrate.sh | head -6
```

Expected: Both should use `--skip-plugins --skip-themes` (though wp_remote has additional SSH logic).

**Step 3: Test script syntax**

Run: `bash -n wp-migrate.sh`

Expected: No output (clean exit means valid syntax).

**Step 4: Verify help text is accessible**

Run: `./wp-migrate.sh --help | wc -l`

Expected: Should show a reasonable line count (200+), confirming help text generates correctly.

**Step 5: Document completion**

All tasks complete. The implementation:
- ✅ Makes wp_local() consistent with wp_remote()
- ✅ Provides automatic error recovery from plugin/theme errors
- ✅ Documents behavior in help text and CHANGELOG
- ✅ Passes shellcheck validation
- ✅ No breaking changes (all commands work without plugins/themes)

---

## Testing Notes for Manual Verification

**After this plan is complete**, you should test with real scenarios (optional but recommended):

1. **Test with broken plugin:**
   - Create a plugin that causes fatal error
   - Run migration or rollback
   - Verify: Script completes successfully despite plugin error

2. **Test help text:**
   ```bash
   ./wp-migrate.sh --help
   ```
   - Verify: NOTES section appears and is readable

3. **Test normal migration:**
   ```bash
   ./wp-migrate.sh --dry-run --verbose
   ```
   - Verify: No change in behavior (operations work as before)

---

## Success Criteria

- [ ] wp_local() uses `--skip-plugins --skip-themes`
- [ ] wp_local() matches wp_remote() behavior pattern
- [ ] Help text includes NOTES section explaining skip behavior
- [ ] CHANGELOG.md has entry under [Unreleased] -> ### Changed
- [ ] ShellCheck passes cleanly
- [ ] Built script (wp-migrate.sh) includes all changes
- [ ] Checksum updated (wp-migrate.sh.sha256)
- [ ] All commits follow conventional commit format

## Execution Notes

- **Important:** All modifications go in `src/` files, never edit `wp-migrate.sh` directly
- **Important:** Run `make build` after modifying `src/` files
- **Important:** Verify shellcheck passes before committing
- **Important:** Commit after each task completes

## Related Skills

- @superpowers:executing-plans - Use this to execute this plan
- @superpowers:subagent-driven-development - Alternative execution approach
- @superpowers:verification-before-completion - Use before marking complete
