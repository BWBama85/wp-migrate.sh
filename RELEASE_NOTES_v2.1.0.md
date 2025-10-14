# v2.1.0 - Jetpack Backup Adapter

**Release Date:** 2025-10-14

This release adds **Jetpack Backup** as the second supported archive format, demonstrating the extensible adapter system working as designed. Users can now import both **Duplicator** and **Jetpack Backup** archives with automatic format detection.

---

## What's New

### Jetpack Backup Adapter

The biggest addition is support for Jetpack Backup archives:

- **Multiple Format Support**: Handles ZIP, TAR.GZ, or already-extracted directories
- **Multi-File SQL Consolidation**: Jetpack stores one SQL file per table (60+ files) - automatically consolidates into single dump for import
- **Auto-Detection**: Detects Jetpack backups via `meta.json` signature file + `sql/wp_options.sql` presence
- **Table Prefix Detection**: Extracts prefix from SQL filenames (e.g., `wp_options.sql` → `wp_`)
- **Smart Content Location**: Finds wp-content at root level of backup
- **Cross-Platform Compatible**: Works on Linux, macOS (Bash 3.2, BSD tools), and BSD systems

### Usage Examples

```bash
# Auto-detect format (works with both Duplicator and Jetpack)
./wp-migrate.sh --archive /backups/site-backup.tar.gz

# Explicit Jetpack format
./wp-migrate.sh --archive /backups/jetpack-backup.tar.gz --archive-type jetpack

# Works with extracted directories (no archive file needed)
./wp-migrate.sh --archive ~/Downloads/jetpack-backup-extracted/

# Duplicator still works exactly as before
./wp-migrate.sh --archive /backups/duplicator-site.zip
```

### Jetpack Backup Format Details

Jetpack backups have a unique structure:
- **`meta.json`**: Contains WordPress version, plugins, themes metadata
- **`sql/` directory**: Individual SQL files per database table (e.g., `wp_options.sql`, `wp_posts.sql`)
- **`wp-content/`**: WordPress content directory at root
- **`wp-config.php`**: WordPress configuration file

The adapter automatically:
1. Detects the format via signature files
2. Consolidates 60+ SQL files into a single database dump
3. Extracts table prefix from filenames
4. Locates wp-content directory
5. Imports using standard wp-migrate.sh workflow

---

## Fixes

### Cross-Platform Compatibility

All fixes ensure the Jetpack adapter works flawlessly across platforms:

- **HIGH**: Added tar dependency check to prevent cryptic "command not found" errors during archive detection. With `set -e` enabled, missing `tar` would kill the script before showing the friendly dependency message. Now checks for both `unzip` (Duplicator) and `tar` (Jetpack) upfront.

- **HIGH**: Fixed BSD sort incompatibility. Replaced GNU-specific `sort -z` with portable array sorting using `printf` and `while read`. BSD sort (macOS default) doesn't support the `-z` flag, causing Jetpack imports to fail on macOS. The new approach works on all platforms.

- **HIGH**: Fixed Bash 3.2 incompatibility. Replaced `mapfile` (Bash 4+) with portable `while read` loop for collecting SQL files. Prevents "mapfile: command not found" errors on macOS which ships with Bash 3.2 by default.

- **MEDIUM**: Fixed hidden files being skipped when copying extracted backup directories. Changed `cp -a "$archive"/* "$dest/"` to `cp -a "$archive"/. "$dest"/` to include dotfiles like `.htaccess` and `.user.ini` which are critical for site configuration.

---

## Documentation Updates

- Updated README.md throughout to reflect both Duplicator and Jetpack support
- Removed all "Duplicator only" statements
- Added examples showing both archive formats
- Updated dependency requirements (added `tar` for Jetpack)
- Updated workflow descriptions to mention both formats

---

## Technical Details

### Supported Archive Formats

| Format | Archive Type | Database Structure | Auto-Detect Signature |
|--------|--------------|-------------------|----------------------|
| **Duplicator** | ZIP | Single SQL file | `installer.php` or `dup-installer/dup-database__*.sql` |
| **Jetpack Backup** | ZIP, TAR.GZ, TAR, Directory | Multiple SQL files (one per table) | `meta.json` + `sql/wp_options.sql` |

### Platform Compatibility

Tested and working on:
- ✅ **Linux**: Bash 4+, GNU tools
- ✅ **macOS**: Bash 3.2, BSD tools (sort, tar, cp)
- ✅ **BSD**: Bash 3.2+, BSD tools

### Code Quality

- ✅ ShellCheck passes with 0 warnings
- ✅ No GNU-specific commands
- ✅ Bash 3.2 compatible throughout
- ✅ Follows existing code style and conventions

---

## Upgrade Guide

### For End Users

**No action required!** Download the new version and use it exactly as before:

```bash
# Download v2.1.0
curl -O https://raw.githubusercontent.com/BWBama85/wp-migrate.sh/main/wp-migrate.sh

# Verify checksum
curl -O https://raw.githubusercontent.com/BWBama85/wp-migrate.sh/main/wp-migrate.sh.sha256
shasum -c wp-migrate.sh.sha256

# Use as normal - now supports both formats
./wp-migrate.sh --archive /backups/duplicator-site.zip
./wp-migrate.sh --archive /backups/jetpack-backup.tar.gz
```

### For Contributors

If you're adding new archive adapters, the Jetpack adapter serves as an excellent reference implementation:
- See `src/lib/adapters/jetpack.sh` for complete working example
- See `src/lib/adapters/README.md` for adapter development guide
- Jetpack demonstrates handling of multi-file databases and directory-based backups

---

## Breaking Changes

**None.** This is a minor version bump (v2.0.0 → v2.1.0) with full backward compatibility.

---

## Detailed Changelog

### Added
- Jetpack Backup adapter supporting ZIP, TAR.GZ, TAR, and extracted directory formats
- Multi-file SQL consolidation for Jetpack's per-table SQL structure
- Auto-detection via `meta.json` + `sql/wp_options.sql` signature
- Table prefix extraction from SQL filenames
- Support for already-extracted backup directories

### Changed
- Updated `AVAILABLE_ADAPTERS` array to include "jetpack"
- Updated Makefile build order to include `src/lib/adapters/jetpack.sh`
- Updated README.md to document both Duplicator and Jetpack support
- Updated help text and examples to show both formats

### Fixed
- tar dependency check (prevents cryptic errors during detection)
- BSD sort compatibility (replaced `sort -z` with portable approach)
- Bash 3.2 mapfile compatibility (replaced with `while read` loop)
- Hidden files preservation in directory copy (`.htaccess`, `.user.ini`)
- Documentation accuracy (removed "Duplicator only" statements)

---

## Download

Download the script:
```bash
curl -O https://raw.githubusercontent.com/BWBama85/wp-migrate.sh/main/wp-migrate.sh
```

Verify the checksum:
```bash
curl -O https://raw.githubusercontent.com/BWBama85/wp-migrate.sh/main/wp-migrate.sh.sha256
shasum -c wp-migrate.sh.sha256
```

---

## What's Next?

With two adapters successfully implemented, the extensible architecture is proven. Future adapters being considered:

- **UpdraftPlus** (multiple separate files for database, plugins, themes, uploads)
- **BackWPup** (TAR/ZIP with specific directory structure)
- **All-in-One WP Migration** (.wpress format)

Contributors can add new formats by following the guide in [src/lib/adapters/README.md](https://github.com/BWBama85/wp-migrate.sh/blob/main/src/lib/adapters/README.md). Adding a new format typically requires ~100-200 lines of code in a single adapter file.

---

**Full Changelog**: [v2.0.0...v2.1.0](https://github.com/BWBama85/wp-migrate.sh/compare/v2.0.0...v2.1.0)
