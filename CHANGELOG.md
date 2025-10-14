# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed (v2.0.0 - Development)
- **[v2 ONLY]** Modularized source code into `src/` directory structure for easier maintenance and code review. Script is now built from modular files using a Makefile. End users see no difference - still download a single `wp-migrate.sh` file. Development structure: `src/header.sh` (defaults), `src/lib/core.sh` (utilities), `src/lib/functions.sh` (all functions), `src/main.sh` (argument parsing and execution flow). Build with `make build` to generate `dist/wp-migrate.sh`.
- **[v2 ONLY]** Added Makefile build system with targets: `make build` (concatenate source files), `make test` (run shellcheck), `make clean` (remove build artifacts). Developers work in modular `src/` files and run `make build` to update the single-file `wp-migrate.sh` at repo root. Uses `shasum -a 256` for cross-platform checksum generation (macOS/Linux compatible).
- **[v2 ONLY]** Added dual-branch workflow to `.claude/settings.json` with separate workflows for v1.x.x maintenance (main branch) and v2.0.0 development (v2 branch). Branch naming enforces target: `v2-*` branches must PR to v2, regular branches PR to main.
- **[v2 ONLY]** Added pre-commit git hook (`.githooks/pre-commit`) that prevents committing source changes without rebuilding `wp-migrate.sh` and `wp-migrate.sh.sha256`. Blocks commits if `src/` files are modified but either the built script or its checksum is not staged. Install with `ln -s ../../.githooks/pre-commit .git/hooks/pre-commit`.
- **[v2 ONLY]** Expanded README Development section with detailed instructions for building from source, git hook setup, Makefile targets, and contribution guidelines for v2+ development.

### Added (v2.0.0 - Development)
- **[v2 ONLY]** Added `--preserve-dest-plugins` flag to preserve destination plugins and themes that are not present in the source during migration. When enabled, the script detects unique destination plugins/themes before migration, then restores them after wp-content sync and automatically deactivates restored plugins (themes remain available but inactive). Automatically enabled when using `--stellarsites` flag. Works in both push and Duplicator modes. Use case: Managed hosting with host-specific plugins/themes that users may want to keep available for later activation.

### Fixed (v2.0.0 - Development)
- **[v2 ONLY]** Made table prefix update failures fatal to prevent silent migration failures. In both push and Duplicator modes, if both `wp config set` and sed fallback fail to update the table prefix in wp-config.php, the script now aborts with a clear error message instead of continuing with a broken configuration. Previously would log an error but continue, resulting in a "successful" migration with a non-functional site.
- **[v2 ONLY]** Enhanced Duplicator mode prefix detection fallback logic. When table prefix detection fails (missing core tables), the script now verifies that the assumed prefix is correct by querying the options table before continuing. If verification fails, the script aborts with a detailed error message explaining possible causes (corrupt database, invalid archive). This prevents silent failures where the script continues with an incorrect prefix assumption.

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
