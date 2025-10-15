# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Solid Backups adapter**: Added support for Solid Backups (formerly BackupBuddy/iThemes Backup) archive format. Handles ZIP archives containing full WordPress installation with split database files in `wp-content/uploads/backupbuddy_temp/{BACKUP_ID}/`. Database is stored as multiple SQL files (one per table) which are automatically consolidated during import. Signature detection via `importbuddy.php` and `backupbuddy_dat.php` files.

### Fixed
- **Critical: Dependency error message syntax error**: Fixed bash syntax error in `needs()` function that prevented dependency error messages from displaying. The issue was caused by multi-line strings inside `echo` commands within a case statement inside command substitution `$(...)`. Refactored to extract installation instructions into separate `get_install_instructions()` helper function using heredocs. Script now properly displays installation instructions when dependencies (wp-cli, rsync, ssh, gzip, unzip, tar, file) are missing. Bug introduced in v2.2.0 (PR #38).

## [2.2.0] - 2025-10-14

**🔍 Observability & Error Guidance: Enhanced Logging & Troubleshooting**

This minor release adds comprehensive logging capabilities (`--verbose` and `--trace` flags) and significantly improves error messages with actionable troubleshooting guidance. A 4-phase improvement initiative spanning 60+ log calls and 25+ enhanced error messages.

### Added
- **Logging infrastructure**: Added `--verbose` and `--trace` flags for enhanced logging and debugging. `--verbose` shows additional details like dependency checks, command construction, and detection processes. `--trace` displays every command before execution with full arguments (implies `--verbose`). Provides complete observability into migration workflow.
- **Enhanced verbose logging**: Added 44 verbose log calls throughout migration workflow. WordPress environment detection (multisite, Redis, URLs, wp-content paths), command construction (rsync options, exclusions, SSH commands), plugin/theme preservation (scanning, counting, uniqueness detection), table prefix operations (verification, fallback logic), and dependency checks. Users can now see decision points and intermediate results with `--verbose` flag.
- **Enhanced trace logging**: Added 16 trace calls for command execution visibility. Traces all WP-CLI commands (`wp_local`/`wp_remote`), SSH commands (`ssh_run`), rsync operations, archive extraction (unzip, tar, cp), and file backup operations. Combined with existing trace coverage, users now have complete command visibility with `--trace` flag. All critical operations traced: database exports/imports, search-replace, archive extraction, file copies, rsync syncs.
- **Enhanced error messages**: Improved 25+ error messages throughout the script with actionable "next steps" guidance. Validation errors (unknown arguments, missing flags, invalid URLs) now include examples and common mistakes. Connection errors (SSH failures, WordPress not detected) now include diagnostic commands and troubleshooting steps. Archive errors (extraction failures, missing database/wp-content) now explain possible causes and provide manual verification commands. Database errors (prefix mismatch, table detection failures) now include recovery procedures and manual fix instructions. Dependency errors (missing wp-cli, rsync, gzip) now include OS-specific installation commands for macOS, Debian/Ubuntu, and RHEL/CentOS.

### Fixed
- **Critical: Logging functions now write to stderr**: All logging functions (`log()`, `log_verbose()`, `log_trace()`, `log_warning()`) now write to stderr instead of stdout. This prevents log output from contaminating command substitutions like `PREFIX="$(wp_local db prefix)"`. Without this fix, `--trace` flag would break 100% of migrations by capturing trace output in variables, causing prefix mismatches, URL alignment failures, and database import errors. Trace output is still visible in terminal but bypasses command substitutions.

## [2.1.1] - 2025-10-14

**📚 Documentation-Only Release: Comprehensive Flag Documentation**

This patch release significantly improves documentation quality with no code changes. All 15 flags are now properly documented with clear descriptions, usage examples, and logical organization.

### Changed
- **Documentation**: Comprehensive overhaul of README.md Options section. Reorganized all flags into logical categories (Required, Database, Source Site, URL Overrides, Transfer, Preservation). Added missing documentation for `--stellarsites` and `--preserve-dest-plugins` flags. Enhanced descriptions with usage examples, default behavior explanations, and cross-references. All 15 flags now documented with clear, detailed descriptions.

### Fixed
- **Documentation**: Corrected `--stellarsites` description to match actual implementation. Changed from incorrect "Uses rsync --delete --ignore-errors" to accurate "excludes mu-plugins/ directory and mu-plugins.php loader file". The flag adds rsync exclusions (--exclude=/mu-plugins/ --exclude=/mu-plugins.php) rather than modifying rsync flags.

## [2.1.0] - 2025-10-14

**🚀 Second Archive Format: Jetpack Backup Support**

This release adds Jetpack Backup as the second supported archive format, demonstrating the extensible adapter system working as designed. Users can now import both Duplicator and Jetpack Backup archives with automatic format detection.

### Added
- **Jetpack Backup adapter**: Added support for Jetpack Backup archives (ZIP, TAR.GZ, or extracted directory format). Handles Jetpack's multi-file SQL structure (one table per file in `sql/` directory) by consolidating into a single database dump before import. Auto-detects Jetpack backups via `meta.json` signature file and `sql/wp_options.sql` presence. Supports both archive files and already-extracted directory paths. Table prefix detection extracts from SQL filenames (e.g., `wp_options.sql` → `wp_`). wp-content location detected at root level of backup. Example: `./wp-migrate.sh --archive /path/to/jetpack-backup.tar.gz` or `./wp-migrate.sh --archive /path/to/extracted-jetpack-backup/`.

### Changed
- Updated `AVAILABLE_ADAPTERS` to include "jetpack" alongside "duplicator" for auto-detection
- Updated Makefile build order to include `src/lib/adapters/jetpack.sh` in concatenation
- Updated README.md and help text to reflect Jetpack Backup support (no longer states "Duplicator only")

### Fixed
- **HIGH**: Fixed missing tar dependency check causing cryptic "command not found" errors during Jetpack archive detection. Added explicit `tar` check in preflight alongside existing `unzip` check. With `set -e` enabled, calling `tar -tzf` during adapter validation would kill the script before the friendly dependency error message. Now checks for both `unzip` (Duplicator) and `tar` (Jetpack) before attempting archive detection.
- **HIGH**: Fixed BSD sort incompatibility in Jetpack adapter. Replaced `sort -z` (GNU-only) with portable array sorting using `printf` and `while read`. BSD sort (default on macOS) doesn't support `-z` flag, causing Jetpack imports to fail on macOS. New approach works on all platforms (Linux, macOS, BSD).
- **HIGH**: Fixed Bash 3.2 incompatibility in Jetpack adapter. Replaced `mapfile` (Bash 4+) with portable `while read` loop for collecting SQL files. Prevents "mapfile: command not found" errors on macOS (default Bash 3.2) when importing Jetpack backups.
- **MEDIUM**: Fixed Jetpack adapter silently skipping hidden files when copying extracted backup directories. Changed `cp -a "$archive"/* "$dest/"` to `cp -a "$archive"/. "$dest"/` to include dotfiles like `.htaccess` and `.user.ini` which are critical for site configuration.

### Added (v2.0.0 - Development)
- **[v2 ONLY]** **Archive Adapter System**: Implemented extensible plugin adapter architecture for supporting multiple WordPress backup formats. Currently ships with Duplicator adapter only; designed to support Jetpack, UpdraftPlus, BackWPup, and other formats in future releases. Each backup plugin format is handled by its own adapter module in `src/lib/adapters/`. Includes auto-detection of archive formats and manual override via `--archive-type` flag. Maintainers can add new formats by creating a single adapter file without modifying core code (see `src/lib/adapters/README.md` for contributor guide).
- **[v2 ONLY]** **New `--archive` flag**: Replaces `--duplicator-archive` as the primary archive import flag. Supports any backup format via the adapter system. Example: `--archive /path/to/backup.zip` with optional `--archive-type duplicator` for explicit format specification.
- **[v2 ONLY]** **Adapter contributor documentation**: Created comprehensive `src/lib/adapters/README.md` guide for adding new backup format support. Includes adapter interface specification, implementation examples, testing checklist, and common pitfalls to avoid.
- **[v2 ONLY]** **Duplicator adapter**: Moved all Duplicator-specific logic into `src/lib/adapters/duplicator.sh` as the first adapter implementation. Serves as reference implementation for future adapters.
- **[v2 ONLY]** **Base adapter helpers**: Created `src/lib/adapters/base.sh` with shared functions for archive detection, wp-content scoring, and format identification that all adapters can use.

### Changed (v2.0.0 - Development)
- **[v2 ONLY]** **BREAKING**: Renamed "Duplicator mode" to "archive mode" throughout codebase. Migration mode is now detected as `MIGRATION_MODE="archive"` instead of `"duplicator"`. Log files now named `migrate-archive-import-*.log` instead of `migrate-duplicator-import-*.log`.
- **[v2 ONLY]** **BREAKING**: Internal variable names changed: `DUPLICATOR_ARCHIVE` → `ARCHIVE_FILE`, `DUPLICATOR_EXTRACT_DIR` → `ARCHIVE_EXTRACT_DIR`, `DUPLICATOR_DB_FILE` → `ARCHIVE_DB_FILE`, `DUPLICATOR_WP_CONTENT` → `ARCHIVE_WP_CONTENT`. User-facing `--duplicator-archive` flag maintained for backward compatibility.
- **[v2 ONLY]** **BREAKING**: Function names changed: `check_disk_space_for_duplicator()` → `check_disk_space_for_archive()`, `extract_duplicator_archive()` → `extract_archive_to_temp()`, `find_duplicator_database()` → `find_archive_database_file()`, `find_duplicator_wp_content()` → `find_archive_wp_content_dir()`, `cleanup_duplicator_temp()` → `cleanup_archive_temp()`.
- **[v2 ONLY]** Updated Makefile to include `src/lib/adapters/*.sh` files in build concatenation order. Build order: header → core → adapters (base, duplicator, ...) → functions → main.
- **[v2 ONLY]** Updated help text to reflect archive mode terminology and new `--archive` flag. Added examples for explicit format specification with `--archive-type`.
- **[v2 ONLY]** Modularized source code into `src/` directory structure for easier maintenance and code review. Script is now built from modular files using a Makefile. End users see no difference - still download a single `wp-migrate.sh` file. Development structure: `src/header.sh` (defaults), `src/lib/core.sh` (utilities), `src/lib/adapters/` (format handlers), `src/lib/functions.sh` (all functions), `src/main.sh` (argument parsing and execution flow). Build with `make build` to generate `dist/wp-migrate.sh`.
- **[v2 ONLY]** Added Makefile build system with targets: `make build` (concatenate source files), `make test` (run shellcheck), `make clean` (remove build artifacts). Developers work in modular `src/` files and run `make build` to update the single-file `wp-migrate.sh` at repo root. Uses `shasum -a 256` for cross-platform checksum generation (macOS/Linux compatible).
- **[v2 ONLY]** Added dual-branch workflow to `.claude/settings.json` with separate workflows for v1.x.x maintenance (main branch) and v2.0.0 development (v2 branch). Branch naming enforces target: `v2-*` branches must PR to v2, regular branches PR to main.
- **[v2 ONLY]** Added pre-commit git hook (`.githooks/pre-commit`) that prevents committing source changes without rebuilding `wp-migrate.sh` and `wp-migrate.sh.sha256`. Blocks commits if `src/` files are modified but either the built script or its checksum is not staged. Install with `ln -s ../../.githooks/pre-commit .git/hooks/pre-commit`.
- **[v2 ONLY]** Expanded README Development section with detailed instructions for building from source, git hook setup, Makefile targets, and contribution guidelines for v2+ development.

- **[v2 ONLY]** Added `--preserve-dest-plugins` flag to preserve destination plugins and themes that are not present in the source during migration. When enabled, the script detects unique destination plugins/themes before migration, then restores them after wp-content sync and automatically deactivates restored plugins (themes remain available but inactive). Automatically enabled when using `--stellarsites` flag. Works in both push and archive modes. Use case: Managed hosting with host-specific plugins/themes that users may want to keep available for later activation.

### Deprecated (v2.0.0 - Development)
- **[v2 ONLY]** `--duplicator-archive` flag deprecated in favor of `--archive`. Backward compatibility maintained - the old flag still works and is internally converted to `--archive --archive-type=duplicator`. Will be removed in v3.0.0.

### Fixed (v2.0.0 - Development)
- **[v2 ONLY]** **HIGH**: Fixed preserve-dest-plugins broken in archive mode. After merge of PR #26 (preserve-dest-plugins) into PR #27 (archive adapter system), the preservation code still referenced old variable name `DUPLICATOR_WP_CONTENT` instead of renamed `ARCHIVE_WP_CONTENT`. With `set -u` enabled, this caused immediate script abortion when using `--stellarsites` or `--preserve-dest-plugins` flags in archive mode. Fixed by updating `detect_archive_plugins()` and `detect_archive_themes()` calls to use correct variable name.
- **[v2 ONLY]** **CRITICAL**: Fixed archive mode completely broken in single-file build. Removed dynamic `source` calls that tried to load adapter files at runtime (files don't exist in built artifact). The Makefile already concatenates all adapter code into the single `wp-migrate.sh` file, so these source calls were unnecessary and caused "No such file or directory" errors. Simplified `load_adapter()` to just verify adapter functions exist (already defined via concatenation) and removed `source` call from main.sh. Archive mode now works correctly in the distributed single-file script.
- **[v2 ONLY]** **HIGH**: Fixed cryptic "command not found" errors during adapter detection. Moved dependency checks before adapter detection logic. Previously, `detect_adapter()` would call validate functions that immediately use `file` and `unzip` commands without checking availability. With `set -e` enabled, missing tools caused script to terminate with bare "command not found" before reaching the friendly "missing dependency" error in `check_adapter_dependencies()`. Now checks for `file` and `unzip` (required by Duplicator adapter) before attempting detection, providing clear installation instructions if missing. When future TAR-based adapters are added, this check can be made conditional based on which adapters are available.
- **[v2 ONLY]** **HIGH**: Fixed `set -e` causing silent exits with corrupt archives. Wrapped `find_archive_database()` and `find_archive_wp_content()` calls in `if !` blocks to capture non-zero exit status before `set -e` kills the script. Previously, adapter functions returning failure would terminate without showing the helpful "Unable to locate database/wp-content" error messages. Now properly displays user-friendly error explaining what went wrong and how to verify the archive.
- **[v2 ONLY]** **HIGH**: Fixed uncompressed TAR archives failing validation. `adapter_base_archive_contains()` was using `tar -tzf` for all tar files, but the `-z` flag only works for gzip-compressed archives. Uncompressed `.tar` files would fail with exit status 2, causing validation to fail silently. Now uses `adapter_base_get_archive_type()` to detect archive type and applies appropriate flags: `tar -tf` for uncompressed `.tar`, `tar -tzf` for `.tar.gz`. This fix enables future adapters supporting plain TAR backups.
- **[v2 ONLY]** **MEDIUM**: Updated README.md and CHANGELOG.md to accurately reflect currently supported formats. Changed documentation from promising "Duplicator, Jetpack, UpdraftPlus, etc." to stating "currently Duplicator only; designed to support additional formats in future releases." Removed example showing `--archive-type jetpack` (would fail with "Unknown archive type") and replaced with Duplicator-only examples. Added notes explaining the architecture supports adding formats via contributor guide. Prevents user confusion and "Unknown archive type" errors.
- **[v2 ONLY]** Made table prefix update failures fatal to prevent silent migration failures. In both push and archive modes, if both `wp config set` and sed fallback fail to update the table prefix in wp-config.php, the script now aborts with a clear error message instead of continuing with a broken configuration. Previously would log an error but continue, resulting in a "successful" migration with a non-functional site.
- **[v2 ONLY]** Enhanced archive mode prefix detection fallback logic. When table prefix detection fails (missing core tables), the script now verifies that the assumed prefix is correct by querying the options table before continuing. If verification fails, the script aborts with a detailed error message explaining possible causes (corrupt database, invalid archive). This prevents silent failures where the script continues with an incorrect prefix assumption.

## [1.1.8] - 2025-10-10
### Fixed
- Improved non-critical error handling to prevent script abortion during cleanup operations. Maintenance mode disable failures, temporary directory cleanup failures, and cache flush failures now log colored warnings (yellow) but allow the script to complete successfully. This prevents migration success from being blocked by non-essential cleanup tasks. Log files remain clean (no ANSI color codes) for readability and tooling compatibility.

## [1.1.7] - 2025-10-10
### Fixed
- Fixed database reset verification in Duplicator mode. Now verifies that `wp db reset` actually dropped all tables and falls back to manual table dropping if it fails. Prevents silent failures where old tables remain after import, causing database pollution with multiple table prefix sets. Properly captures exit codes and handles both command failures and silent failures.

## [1.1.6] - 2025-10-10
### Added
- Added `--stellarsites` flag for Duplicator mode to handle managed hosts with protected mu-plugins directories. When enabled, uses root-anchored rsync exclusions (`/mu-plugins/`, `/mu-plugins.php`, `/object-cache.php`) to preserve host-specific files at wp-content root while still using `--delete` to ensure a clean migration of all other files. This prevents silent data loss from unanchored patterns while maintaining compatibility with StellarSites and similar managed hosting.

## [1.1.5] - 2025-10-09
### Fixed
- Fixed table prefix update in wp-config.php for both push and Duplicator modes. Added verification after `wp config set` and automatic fallback to sed when WP-CLI fails to write prefixes with leading underscores (e.g., `__wp_` incorrectly written as `wp_`). Affects edge case prefixes but ensures correct wp-config.php updates in all cases.

## [1.1.4] - 2025-10-09
### Fixed
- Fixed URL search-replace in both push and Duplicator modes by running separate `wp search-replace` commands for each old/new URL pair. Previously passed all pairs in one command, causing WP-CLI to interpret extra arguments as table names and fail with "Couldn't find any tables matching" error.

## [1.1.3] - 2025-10-09
### Fixed
- Fixed duplicate primary key errors in Duplicator mode by resetting database before import. Duplicator SQL dumps contain INSERT statements that conflict with existing destination data.

## [1.1.2] - 2025-10-09
### Fixed
- Excluded `object-cache.php` from wp-content transfers in both push and Duplicator modes to prevent fatal errors when source site uses caching infrastructure (Redis, Memcache, etc.) not available on destination server.

## [1.1.1] - 2025-10-09
### Fixed
- Fixed arithmetic expansion causing exit with `set -e` in wp-content detection for Duplicator mode. Changed `((score++))` to `score=$((score + 1))` to ensure command always succeeds.

## [1.1.0] - 2025-10-09
### Added
- Added Duplicator archive import mode via `--duplicator-archive` flag for importing Duplicator WordPress backup archives without requiring SSH access to the source server.
- Automatic extraction and detection of database and wp-content from Duplicator .zip archives with smart directory scoring.
- Pre-flight disk space validation ensuring 3x archive size is available (archive + extraction + buffer).
- Automatic backup of both destination database and wp-content before any destructive operations in Duplicator mode.
- URL detection and search-replace automatically aligns imported site URLs to match the destination site.
- Comprehensive rollback instructions showing exact commands to restore both database and wp-content backups.
- Auto-cleanup of temporary extraction directory on success, kept on failure for debugging.
- Mutually exclusive mode detection prevents conflicting flag combinations between push and Duplicator modes.

## [1.0.0] - 2025-10-09
### Added
- Expanded automatic wp search-replace to cover protocol-relative, JSON-escaped, and trailing-slash variants of the domain, plus optional `--dest-domain`/`--dest-home-url`/`--dest-site-url` overrides when detection needs a hint.
- Documented the Git workflow and provided supporting templates for commits and pull requests.
- Added comprehensive test suite (`test-wp-migrate.sh`) validating argument parsing, error handling, and code quality without requiring WordPress installations.
- Added `--version` flag (short: `-v`) to display version information from git tags or CHANGELOG.md.
- Added URL format validation for `--dest-home-url` and `--dest-site-url` options to catch invalid URLs early.
- Added early SSH connectivity test to fail fast with helpful error messages when destination host is unreachable.
- Added `--info=progress2` to rsync for real-time file transfer progress indicators during database and wp-content transfers.
- Added rollback instructions logged at migration completion showing exact command to restore backup wp-content directory.

### Changed
- Added ShellCheck disable directives for intentional client-side expansions in SSH commands to achieve zero ShellCheck warnings.

## [Pre-history]
### Added
- `wp-migrate.sh` initial script prior to adopting the tracked changelog.
