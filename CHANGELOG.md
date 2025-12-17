# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **PHP 8.4 deprecation warnings polluting database table listings**: Fixed issue where WP-CLI deprecation warnings (from `react/promise` and `php-cli-tools` libraries) were being included in `SHOW TABLES` output, causing table counts to be incorrect and table drop operations to fail with "Could not drop Deprecated: ..." errors. All database table queries now filter out warning lines.

## [2.10.9] - 2025-12-17

### Fixed

- **PHP 8.4 WP-CLI deprecation warnings polluting paths**: Fixed issue where PHP deprecation warnings from WP-CLI (e.g., `react/promise` library's semicolon syntax warnings) were captured along with the wp-content path, causing "wp-content path is not a directory" errors. Path discovery functions now filter output to only valid absolute paths.
- **Grep pipeline crash with pipefail**: Fixed script crash when WP-CLI returns only warnings with no valid path. Added `|| true` to grep pipeline to allow empty results to reach validation logic instead of crashing with exit code 1.
- **Missing wp-content validation in push mode**: Added comprehensive validation for `SRC_WP_CONTENT` and `DST_WP_CONTENT` in push mode (previously only archive mode validated these). Now validates empty paths, directory existence, and remote writability. Prevents undefined behavior when path discovery fails silently.
- **Plugin restoration path safety**: Fixed potential issue in `restore_dest_content_push()` where inline path discovery could write to wrong location if WP-CLI fails. Now pre-validates wp-content path before restoration operations.

## [2.10.8] - 2025-11-26

### Fixed

- **macOS rsync compatibility**: Fixed "unrecognized option `--info=progress2`" error on macOS by detecting rsync capabilities and falling back to `--progress` for macOS's openrsync. Also falls back from `--info=stats2` to `--stats` where needed.
- **Rsync error detection**: Fixed silent rsync failures where errors were masked by the `tee` pipeline. Now uses `PIPESTATUS` to properly detect and report rsync exit codes.

## [2.10.7] - 2025-11-26

### Fixed

- **Pre-rsync source validation for archive imports**: Added safeguards to catch scenarios where the extracted wp-content directory is missing or incomplete before rsync runs. Validates directory existence and file count (minimum 10 files), with detailed error messages and recovery instructions pointing to the backup location.

### Changed

- **Improved rsync error handling**: Wrapped rsync command in explicit error checking to detect and report sync failures rather than silently continuing.

## [2.10.6] - 2025-11-26

### Fixed

- **False positive security warnings during extraction**: Fixed post-extraction path validation that incorrectly flagged all extracted files as "outside extraction directory" due to path format mismatch (double slash `//` vs normalized paths).

### Security

- **Sibling directory attack prevention**: Improved post-extraction validation to use directory boundary checking instead of naive prefix matching. Prevents attacks where `/tmp/extract-123-malicious/file` would incorrectly match `/tmp/extract-123`.

## [2.10.5] - 2025-11-26

### Fixed

- **Auto-overwrite duplicate files during zip extraction**: Archives containing duplicate filenames no longer cause the script to hang waiting for user input. Added `-o` flag to unzip commands to automatically overwrite duplicates.

## [2.10.4] - 2025-11-25

### Fixed

- **Extraction progress in verbose/trace mode**: When `--verbose` or `--trace` is enabled, extraction commands now show file-by-file progress instead of running silently. Previously, `unzip -q` suppressed all output even with `--trace`, making large archive extractions appear frozen.

## [2.10.3] - 2025-11-25

### Security

- **Plain .tar archive Zip Slip validation**: Fixed security bypass where uncompressed `.tar` archives skipped path traversal validation entirely. The `validate_archive_paths()` function now properly detects and validates plain tar files using `tar -tf` in addition to compressed archives.

### Added

- **Progress feedback for large archive extraction**: Archives over 500MB now display a message indicating extraction may take several minutes, with elapsed time logged upon completion. Uses `pv` with progress bar when available, otherwise falls back to status messages.
- **Plain .tar archive support for Jetpack**: Restored support for uncompressed `.tar` Jetpack backup archives that was accidentally removed during refactoring.
- **New security tests**: Added 3 tests for plain `.tar` archive validation (20 total Zip Slip tests).

### Changed

- **Refactored adapter extraction code**: Consolidated duplicate extraction logic from all adapters into shared helper functions (`adapter_base_extract_zip()`, `adapter_base_extract_tar_gz()`, `adapter_base_extract_tar()`) in `base.sh`, reducing code duplication and ensuring consistent progress feedback across all backup formats.

## [2.10.2] - 2025-11-25

### Fixed

- **Zip Slip false positives on filenames with double periods**: Fixed overly broad path traversal detection that incorrectly flagged legitimate filenames containing `..` (e.g., `John-Smith-Jr..jpg` where a name ending in "Jr." or "Sr." is followed by a file extension). The fix now only detects actual path traversal attempts (`../`, `/../`, `/..`) rather than any occurrence of `..` in the filename.

### Security

- **Windows-style path traversal detection**: Added detection for Windows backslash-based path traversal attempts (`..\`) in addition to Unix-style (`../`).
- **Comprehensive absolute path detection**: Added detection for all Windows absolute path forms including drive letters with backslash (`C:\`), drive letters with forward slash (`C:/`), and UNC paths (`\\server\share`).

### Added

- **Zip Slip regression tests**: New integration test suite (`tests/integration/test-zip-slip-protection.sh`) validates that path traversal attacks are blocked while legitimate filenames with `..` are allowed.

## [2.10.1] - 2025-11-17

**📚 Documentation Updates**

This patch release improves documentation accuracy and removes obsolete files. No functional changes.

### Documentation

- **Comprehensive documentation audit**: Added missing wp-migrate format references throughout README.md (#103, #105)
  - Added wp-migrate format to all 8 locations where archive formats are listed
  - Documented jq dependency requirement for wp-migrate format validation
  - Distinguished Solid Backups Legacy vs NextGen consistently

- **Security feature documentation**: Added comprehensive Security Features section to README.md (#103, #105)
  - Documented v2.10.0 Zip Slip path traversal protection
  - Documented v2.10.0 SQL injection prevention
  - Documented v2.10.0 emergency database snapshot feature

- **WP-CLI documentation**: Added WP-CLI Automatic Error Recovery section to README.md (#103, #105)
  - Documented v2.9.0 automatic `--skip-plugins --skip-themes` flags
  - Explained when and why error recovery helps migrations succeed

- **Troubleshooting expansion**: Expanded troubleshooting from 3 bullets to comprehensive sections (#103, #105)
  - Added guidance for v2.9.0-v2.10.0 scenarios
  - Improved common error resolution steps

- **Developer documentation updates**: Updated CLAUDE.md from v2.8.3 to v2.10.0 (#102, #105)
  - Added v2.10.0 security protections to Key Safety Features
  - Added v2.9.0 WP-CLI error recovery documentation
  - Added v2.8.3 plugin filtering documentation
  - Fixed incorrect version references

- **Test documentation improvements**: Enhanced test suite documentation (#104, #105)
  - Added comprehensive overview of all test types to tests/README.md
  - Documented integration tests for archive format detection
  - Added "What's NOT Tested" section explaining manual test scenarios
  - Documented missing test fixtures and regeneration procedures in tests/fixtures/README.md
  - Updated fixture creation date to 2025-11-17

- **Obsolete file removal**: Deleted 9 outdated/duplicate documentation files (#101, #105)
  - Removed duplicate release notes (RELEASE_NOTES_v2.0.0.md, RELEASE_NOTES_v2.1.0.md, release-notes.md)
  - Removed obsolete IMPLEMENTATION_STATUS.md
  - Removed 5 implementation plan documents for completed features (v2.8.0-v2.9.0)
  - CHANGELOG.md is now the single source of truth for release information

## [2.10.0] - 2025-11-15

**🛡️ Security & Stability Hardening**

This minor release addresses critical security vulnerabilities and data loss scenarios identified during a comprehensive security audit (#89). All critical, high-priority, and medium-priority issues have been resolved.

### Security Fixes

- **CRITICAL: Zip Slip path traversal protection**: Archive extraction now validates all paths to prevent malicious archives from writing files outside the extraction directory (#81, #90)
  - Prevents remote code execution via crafted archives containing paths like `../../etc/passwd`
  - All adapter extraction functions now sanitize and validate paths
  - Archives attempting path traversal are rejected with detailed error messages

- **CRITICAL: SQL injection prevention**: Table name validation added to prevent SQL injection in DROP TABLE operations (#83, #92)
  - Table names must match WordPress naming pattern: `{prefix}_{tablename}` or `{prefix}{number}_{tablename}` (multisite)
  - Prevents malicious table names from executing arbitrary SQL
  - Invalid table names are rejected with detailed error messages

- **CRITICAL: Emergency database snapshot**: Database reset now creates emergency snapshot before dropping tables (#82, #91)
  - Automatic rollback if import fails or produces zero tables
  - Snapshot automatically restored on script exit if needed
  - Prevents permanent database loss from crashes during reset
  - Temporary snapshot cleaned up after successful migration

### Data Protection Fixes

- **CRITICAL: Multi-WordPress database detection**: Script now detects and prevents ambiguous migrations when multiple WordPress installations share a database (#84, #93)
  - Prevents importing from wrong WordPress installation
  - Users must confirm which installation to use
  - Clear error messages with instructions for single-site migration

- **CRITICAL: wp-content backup verification**: Backup operations are now validated before proceeding with destructive changes (#85, #94)
  - Verifies backup directory exists and is not empty
  - Checks backup size matches source (within 10% tolerance)
  - Prevents data loss from failed backup operations
  - Detailed error messages with filesystem diagnostics

- **CRITICAL: Dry-run mode crash fixes**: Dry-run mode no longer crashes when preview logic attempts file operations (#86, #95)
  - All file stat and size operations check $DRY_RUN flag first
  - Dry-run mode now fully functional for testing migrations
  - Provides accurate preview without touching filesystem

### High-Priority Improvements (Issue #87)

- **Resource leak fixes**: Temporary extraction directories are now cleaned up in all exit paths (#96)
  - Added exit_cleanup trap to ensure cleanup even on errors
  - Prevents disk space exhaustion from abandoned temp directories

- **Database import verification**: Import success is validated by checking table count (#96)
  - Zero-table imports are detected and trigger rollback
  - Prevents silent import failures

- **Rollback safety improvements**: Rollback operations now validate both restore and revert operations (#96)
  - Nested validation prevents false success claims
  - Catastrophic failures provide detailed recovery instructions
  - Users always know the true state of their wp-content directory

- **Adapter validation**: ARCHIVE_ADAPTER variable is validated before use (#96)
  - Prevents undefined behavior from invalid adapter names
  - Clear error messages for unsupported archive types

- **Foreign key constraint handling**: Database import now temporarily disables foreign key checks (#96)
  - Prevents import failures from constraint violations
  - Re-enables checks after import completes

- **Emergency snapshot error messages**: Error messages now accurately describe automatic vs manual recovery (#96)
  - Messages explain that automatic rollback will occur
  - No longer reference snapshots that get auto-deleted

### Code Quality Improvements (Issue #88)

- **SQL consolidation deduplication**: Eliminated ~90 lines of duplicate code by creating shared `adapter_base_consolidate_database()` function (#97)
  - All adapters now use common implementation
  - Consistent error handling and logging across formats

- **Adapter detection error reporting**: Removed stderr suppression to improve troubleshooting (#97)
  - Adapter validation errors now visible in verbose mode
  - Helps diagnose archive format issues

- **Pipefail state management**: Added trap-based restoration to prevent pipefail state leakage (#97)
  - Fixes unbound variable errors with set -u
  - Ensures pipefail is restored even on early function exit

- **Directory search optimization**: Adapter directory searches now check shallow depths first (#97)
  - Dramatically improves performance on large archives
  - Reduces false positives from nested test/backup directories

- **wp-content path validation**: Comprehensive validation before using wp-content paths (#97)
  - Verifies path is not empty, is a directory, and is writable
  - Detailed error messages with filesystem diagnostics and recovery steps

- **Error message simplification**: Archive format errors now show only the active adapter's expected pattern (#97)
  - Reduces confusion by eliminating irrelevant format information
  - Users see exactly what their chosen format should contain

- **Array difference documentation**: Clarified space handling in array comparison operations (#97)
  - Documents that quoted expansion preserves items with spaces
  - Prevents future bugs in array manipulation

- **Log file rotation**: Automatic cleanup keeps only the 20 most recent log files (#98)
  - Prevents log directory from growing indefinitely
  - Transparent operation - no user intervention required

- **URL consistency verification**: Post-import verification samples post content for mismatched URLs (#98)
  - Detects if archive contains mixed content from multiple domains
  - Provides actionable search-replace commands for fixes
  - Helps identify incomplete URL replacement in source archives

### Developer Notes

- All fixes maintain backward compatibility
- No changes to command-line interface or behavior
- Existing scripts and workflows continue to work unchanged
- Security improvements are transparent to users

### Upgrade Recommendations

- **Immediate upgrade recommended** for all users due to critical security fixes
- Zip Slip vulnerability (CVE pending) allows arbitrary file writes - upgrade before processing untrusted archives
- Emergency snapshot feature provides automatic recovery - highly recommended for production migrations
- All existing functionality preserved - safe drop-in replacement

## [2.9.0] - 2025-11-13

**🛡️ Enhanced Reliability**

This minor release improves migration reliability by making local WP-CLI operations consistent with remote operations, providing automatic error recovery when plugin or theme errors occur.

### Changed

- **WP-CLI commands now skip plugins/themes by default**: All local WP-CLI operations now use `--skip-plugins --skip-themes` flags (#78)
  - Provides automatic recovery when migrations cause plugin/theme errors
  - Matches existing remote WP-CLI behavior (since v2.0.0)
  - All migration operations work without loading plugin/theme code
  - No functional changes - script uses low-level database/filesystem commands only
  - Added `wp_local_full()` function for plugin-provided commands (Object Cache Pro redis flush)
  - Added NOTES section to help text explaining skip behavior

## [2.8.3] - 2025-11-13

**🔧 Plugin Filtering Fix**

This patch release fixes incorrect plugin preservation behavior that caused restoration warnings for WordPress drop-ins and managed hosting plugins.

### Fixed

- **WordPress drop-ins filtered from preservation**: Drop-ins like `advanced-cache.php`, `db.php`, and `db-error.php` are no longer incorrectly treated as plugins (#72)
  - These files live in `wp-content/` (not `wp-content/plugins/`)
  - Previously caused "Failed to restore plugin" warnings
  - Now properly excluded from plugin preservation logic
- **StellarSites managed plugins filtered**: When using `--stellarsites` flag, managed hosting plugins like `stellarsites-cloud` are excluded from preservation (#73)
  - Prevents restoration warnings for system-protected plugins
  - Only applies when `--stellarsites` mode is enabled
- **Transparent filtering logs**: Added logging to show what was filtered during migration preview
  - Shows: "Filtered drop-ins from preservation: X Y Z"
  - Shows: "Filtered managed plugins from preservation: X Y Z"
- **Dry-run mode detection fixed**: Plugin detection now runs during `--dry-run` mode to enable filtering preview (#75)
  - Previously detection was skipped entirely in dry-run mode
  - Users can now preview filtering behavior with `--dry-run --verbose`

## [2.8.2] - 2025-11-12

**🐛 Critical Bug Fix**

This patch release fixes a critical runtime error that prevented `--stellarsites` and `--preserve-dest-plugins` from working.

### Fixed

- **array_diff bad substitution error**: Fixed "bad substitution" error when using `--stellarsites` or `--preserve-dest-plugins` flags
  - Corrected array_diff function calls to use plain array names without [@] suffix
  - Previously caused double-subscript syntax errors like `${DEST_PLUGINS_BEFORE[@][@]}`
  - Affected both push mode and archive mode plugin/theme preservation logic

## [2.8.1] - 2025-11-11

**🔧 Local Backup Mode & Critical Fixes**

This patch release adds local backup mode and fixes several critical bugs in the backup creation feature.

### Added

- **Local backup mode**: Run `--create-backup` without `--source-host` to back up local WordPress installations
  - No SSH configuration required for local backups
  - Defaults to current directory when run from WordPress root
  - Optional `--source-root` to specify different local path
  - Produces same archive format as remote backups, fully compatible with `--archive` import mode

### Fixed

- **VERSION variable in metadata**: Replaced hardcoded "2.8.0" with $VERSION variable to prevent version drift
- **BACKUP_OUTPUT_DIR honored**: Local backups now respect configured BACKUP_OUTPUT_DIR setting instead of hardcoded path
- **Dedicated backup mode logging**: Local and remote backup modes now have distinct log messages and file names
- **Portable table count**: Fixed unsupported `--format=count` flag, now uses portable `| wc -l` approach
- **BSD/macOS du compatibility**: Replaced GNU-specific `--exclude` flag with portable find-based approach for wp-content size calculation

## [2.8.0] - 2025-11-11

**📦 Backup Creation**

This minor release adds native backup creation capabilities, allowing you to create WordPress backups on source servers via SSH and import them using the existing archive mode.

### Added

- **Backup creation mode**: New `--create-backup` flag creates WordPress backups on source servers via SSH
  - Stores backups in `~/wp-migrate-backups/` with timestamped filenames
  - Includes database dump and wp-content directory
  - Automatically excludes cache directories, object cache files, and debug logs
  - Backups compatible with existing `--archive` import mode
  - Intelligent disk space checking ensures adequate space before creating backup
- **wp-migrate adapter**: New native archive format with JSON metadata
  - Validates backups via `wpmigrate-backup.json` signature file
  - Simple structure: metadata, database.sql, wp-content/
  - First in adapter detection order for fastest validation
  - Graceful jq dependency handling during auto-detection
- **Backup creation flags**:
  - `--source-host`: SSH connection to source server
  - `--source-root`: WordPress root path on source server
  - `--create-backup`: Enable backup creation mode

### Fixed

- Binary unit support (KiB/MiB/GiB/TiB) in database size calculation for accurate disk space estimation
- $HOME path display now shows ~ instead of literal $HOME in success messages for better copy/paste compatibility

## [2.7.0] - 2025-10-21

**📦 Archive Format Support**

This minor release adds support for Solid Backups NextGen archives, the completely rewritten successor to Solid Backups Legacy.

### Added
- **Solid Backups NextGen adapter**: Full support for Solid Backups NextGen archives with completely different structure from Legacy. NextGen stores database in top-level `data/` directory (not `wp-content/uploads/backupbuddy_temp/`), WordPress files in `files/` directory, and metadata in `meta/` directory. Both Solid Backups Legacy and NextGen are now supported with separate adapters (`solidbackups` and `solidbackups_nextgen`). Archive format is auto-detected based on structure, or specify explicitly with `--archive-type solidbackups_nextgen`. Adapter uses depth-first candidate iteration to reliably find correct `data/` and `files/` directories even when WordPress core/plugins contain nested directories with same names (e.g., `wp-includes/ID3/data`, `jetpack/tests/data`). Includes multisite support with `files/subdomains/` structure detection.

## [2.6.0] - 2025-10-20

**🎯 UX & Safety Improvements**

This minor release adds migration preview with confirmation prompts, rollback command, and progress indicators for better user experience and migration safety.

### Added
- **Migration Preview with Confirmation**: Pre-migration summary displays detailed information before starting migration operations. Shows source/destination URLs, database size, file counts, estimated disk space usage, and planned operations list. Includes confirmation prompt "Proceed with migration? [y/N]" (skip with `--yes` or `--dry-run`). Works in both push mode (shows SSH connection details, rsync size, URL alignment plans) and archive mode (shows archive format, extraction size, backup locations). Helps prevent migration mistakes by giving users a chance to review and confirm before making changes.
- **Rollback Command**: New `--rollback` flag to automatically restore from backups created during previous migrations. Auto-detects latest backups from `db-backups/` and `wp-content.backup-*` directories. Includes confirmation prompt (skip with `--yes` for automation), dry-run support, and explicit backup path specification via `--rollback-backup`. Makes it easy to undo a migration if something goes wrong. Works for archive mode migrations (restores both database and wp-content from local backups).
- **--yes flag**: New flag to skip confirmation prompts for automated/non-interactive workflows. Use with caution as it bypasses safety checks. Currently applies to migration preview confirmation and rollback confirmation.
- **Progress Indicators with bsdtar support**: Real-time progress bars for long-running operations when `pv` (pipe viewer) is installed. Shows progress for database imports, archive extraction, and file synchronization operations. Archive extraction uses `bsdtar` when available (supports progress for all formats via stdin), falling back to format-specific tools (`unzip` for ZIP, `tar` for tar.gz/tar) when `bsdtar` is not installed. Progress for ZIP archives requires `bsdtar` since standard `unzip` doesn't support stdin. Progress can be suppressed with the new `--quiet` flag for non-interactive scripts.
- **--quiet flag**: New flag to suppress progress indicators for long-running operations. Useful for non-interactive scripts or automated migrations where progress output is not desired.
- **Optional bsdtar support**: When `bsdtar` is installed, archive extraction shows progress bars for all formats (ZIP, tar.gz, tar). Without `bsdtar`, ZIP extraction works correctly but without progress (since standard `unzip` doesn't support stdin), while tar-based formats still show progress via GNU tar.
- **Integration Test Infrastructure**: Minimal test archives for Duplicator, Jetpack, and Solid Backups formats with automated format detection tests. Includes 3 test fixtures (< 5KB total) and integration test script that validates each adapter correctly identifies its format. CI/CD workflow updated to run integration tests on every push. See `tests/fixtures/README.md` for details.

### Fixed
- **Rollback non-interactive context handling**: Fixed critical bug where rollback confirmation prompt would silently fail in non-interactive contexts (CI/cron/pipelines), causing rollbacks to be skipped while reporting success (exit 0). Now detects non-interactive stdin via `[[ ! -t 0 ]]` and exits with error message instructing users to add `--yes` flag for automation. Mirrors the migration preview protection.
- **Migration preview non-interactive context handling**: Fixed critical bug where confirmation prompt would silently fail in non-interactive contexts (CI/cron/pipelines), causing migrations to be skipped while reporting success (exit 0). Now detects non-interactive stdin via `[[ ! -t 0 ]]` and exits with error message instructing users to add `--yes` flag for automation. This prevents silent failures in existing automation scripts that don't pass `--yes`.
- **Archive mode plugin/theme preservation accuracy**: Fixed misleading preview in archive mode where "Restore unique destination plugins/themes" operation was never shown even when `--stellarsites` or `--preserve-dest-plugins` flags were used. Moved plugin/theme detection to happen before the preview (phase 3c instead of phase 6b) so `UNIQUE_DEST_PLUGINS` and `UNIQUE_DEST_THEMES` arrays are populated when the preview displays the operations list.
- **Push mode plugin/theme preservation accuracy**: Fixed misleading preview in push mode where "Restore unique destination plugins/themes" operation was never shown even when `--stellarsites` or `--preserve-dest-plugins` flags were used. Moved plugin/theme detection to happen before the preview (instead of after) so `UNIQUE_DEST_PLUGINS` and `UNIQUE_DEST_THEMES` arrays are populated when the preview displays the operations list.
- **Archive mode preview wp-content backup path**: Fixed incorrect backup path shown in archive mode preview when `WP_CONTENT_DIR` is customized. Preview now discovers `DEST_WP_CONTENT` before displaying (phase 3b) so the actual backup path is shown instead of a generic `wp-content.backup-*` placeholder.
- **Archive type detection for tar.gz files**: Fixed critical bug in `adapter_base_get_archive_type()` where the function checked for "zip" before "gzip", causing tar.gz files (like Jetpack backups) to be misidentified as ZIP archives. Since "gzip" contains the substring "zip", the condition `*"zip"*` matched first and returned "zip" instead of "tar.gz". This broke Jetpack archive validation completely as the script attempted to use `unzip` on tar.gz files. Fixed by reordering conditions to check for gzip/compressed before zip. (Discovered during PR #54 code review)

### Changed
- **rsync progress in archive mode**: Added `--info=progress2` flag to rsync when syncing wp-content from archive to destination, matching the behavior already present in push mode. Provides consistent progress reporting across both migration modes.

## [2.5.0] - 2025-10-20

**⚡ Quality & Diagnostics**

This minor release adds automated testing infrastructure and significantly improves error diagnostics.

### Added
- **CI/CD Pipeline**: Comprehensive GitHub Actions workflow with 9 job types (13 total job runs with matrix expansion) covering ShellCheck linting, unit tests, Bash compatibility matrix (3.2, 4.0, 4.4, 5.0, 5.1), build validation, security scanning, macOS compatibility, documentation checks, and integration smoke tests. Automated testing runs on every push and pull request to main/develop branches.
- **Enhanced adapter diagnostics**: Archive format detection now provides detailed validation failure reasons for each adapter when auto-detection fails. Error messages show specific reasons why Duplicator, Jetpack, and Solid Backups adapters rejected the archive (e.g., "Missing installer.php", "Not a ZIP archive", "Missing meta.json"), making troubleshooting much easier.
- **Dependency version checking**: Optional version validation for critical dependencies (wp-cli, rsync, ssh, bash). The `needs()` function now accepts a minimum version parameter and warns users if they're running older versions that may cause issues. Version checking uses semantic version comparison and provides upgrade instructions when needed.

## [2.4.2] - 2025-10-16

**🚨 Critical Bug Fix: StellarSites mu-plugins Restoration**

This patch release fixes a critical bug introduced in v2.4.1 where excluded mu-plugins files were never restored from backup in push mode, leaving StellarSites environments completely broken.

### Fixed
- **CRITICAL: --stellarsites mu-plugins restoration in push mode**: Fixed critical bug where excluded mu-plugins files were never restored from backup in push mode, leaving StellarSites environments completely broken after migration. Push mode moves wp-content to backup, then rsync creates new wp-content with `--exclude=/mu-plugins/`. Previously, the excluded files stayed in the backup and were never copied back, resulting in missing `mu-plugins/` directory and `mu-plugins.php` loader file. Now properly restores both from backup after rsync completes, ensuring managed hosting environments have their required system plugins. Also fixed logging to only show success messages when restoration actually succeeds (not when it fails).

## [2.4.1] - 2025-10-16

**🐛 Bug Fix: StellarSites Push Mode**

This patch release fixes a critical bug where the `--stellarsites` flag didn't work correctly in push mode.

### Fixed
- **--stellarsites flag in push mode**: Fixed `--stellarsites` flag to properly exclude `mu-plugins/` directory and `mu-plugins.php` loader file in push mode. Previously, the flag only worked correctly in archive mode. In push mode, it would auto-enable `--preserve-dest-plugins` but fail to exclude the protected mu-plugins files, causing rsync to attempt overwriting them and triggering permission errors on managed hosts. Now both push and archive modes correctly exclude mu-plugins files when `--stellarsites` is set, matching the documented behavior of "Works in both push and archive modes."

## [2.4.0] - 2025-10-15

**⚡ Faster Migrations: Optional Search-Replace**

This minor release adds the `--no-search-replace` flag for faster migrations when bulk URL replacement isn't needed.

### Added
- **--no-search-replace flag**: Added `--no-search-replace` flag to skip bulk search-replace operations while still updating home and siteurl options. Useful for faster migrations when you only need the site to load at the destination URL but don't need to replace URLs in post content, metadata, or other options. When flag is set, only the home and siteurl WordPress options are updated to destination URLs; all other content remains unchanged. The script logs a clear warning about this behavior and provides the manual wp search-replace command if needed later. Works in both push mode (direct migration) and archive mode (backup restore). Dry-run preview accurately reflects the flag's behavior. Use cases: quick staging deployments, content migrations where URLs in posts don't matter, or situations where you'll run custom search-replace later.

## [2.3.0] - 2025-10-15

**🔌 Third Archive Format + Critical Bug Fix**

This minor release adds support for Solid Backups (formerly BackupBuddy) archives and fixes a critical syntax error that prevented the script from running since v2.2.0.

### Added
- **Solid Backups adapter**: Added support for Solid Backups (formerly BackupBuddy/iThemes Backup) archive format. Handles ZIP archives containing full WordPress installation with split database files in `wp-content/uploads/backupbuddy_temp/{BACKUP_ID}/`. Database is stored as multiple SQL files (one per table) which are automatically consolidated during import. Signature detection via `importbuddy.php` and `backupbuddy_dat.php` files. Custom table prefix support using `*.sql` pattern matching. Updated all CLI error messages and help text to include Solid Backups guidance. Three archive formats now supported: Duplicator, Jetpack Backup, and Solid Backups.

### Fixed
- **Critical: Dependency error message syntax error**: Fixed bash syntax error in `needs()` function that prevented the script from running at all. The issue was caused by multi-line strings inside `echo` commands within a case statement inside command substitution `$(...)`. Refactored to extract installation instructions into separate `get_install_instructions()` helper function using heredocs. Script now properly displays installation instructions when dependencies (wp-cli, rsync, ssh, gzip, unzip, tar, file) are missing. Bug introduced in v2.2.0 (PR #38).

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
