# Test Fixtures

This directory contains minimal test archives for integration testing of wp-migrate.sh's archive format detection.

## Overview

Each test archive is a **minimal** valid archive that contains just enough structure to satisfy the format detection logic for its respective backup plugin adapter.

**⚠️ These are NOT real backups** - they contain stub data only and cannot be used for actual WordPress migrations.

## Test Archives

### 1. duplicator-minimal.zip (1.9 KB)

**Format**: Duplicator Pro/Lite
**Type**: ZIP archive
**Contents**:
- `installer.php` - Signature file for Duplicator format detection
- `dup-installer/dup-database__test123.sql` - Minimal SQL stub with wp_options table
- `wp-content/` - Minimal directory structure

**Detection**: Validated by presence of `installer.php` or `dup-installer/dup-database__*.sql` pattern

### 2. jetpack-minimal.tar.gz (1.1 KB)

**Format**: Jetpack Backup
**Type**: TAR.GZ archive
**Contents**:
- `meta.json` - Jetpack metadata file (required signature)
- `sql/wp_options.sql` - Database file in Jetpack multi-file format
- `wp-content/` - Minimal directory structure

**Detection**: Validated by presence of both `meta.json` AND `sql/wp_options.sql`

### 3. solidbackups-minimal.zip (2.0 KB)

**Format**: Solid Backups (formerly BackupBuddy)
**Type**: ZIP archive
**Contents**:
- `wp-content/uploads/backupbuddy_temp/test123abc/importbuddy.php` - Signature file
- `wp-content/uploads/backupbuddy_temp/test123abc/wp_options.sql` - Database file
- `wp-content/plugins/` - Minimal directory structure

**Detection**: Validated by presence of `importbuddy.php` or `backupbuddy_dat.php` in `backupbuddy_temp/`

## Usage in Tests

These fixtures are used by integration tests in `../integration/`:

```bash
# Archive format detection test
./tests/integration/test-archive-detection.sh

# Tests that each archive is correctly identified by its adapter:
# - Duplicator adapter recognizes duplicator-minimal.zip
# - Jetpack adapter recognizes jetpack-minimal.tar.gz
# - Solid Backups adapter recognizes solidbackups-minimal.zip
# - All adapters reject invalid archives
```

## Creating New Test Fixtures

If you need to create additional test fixtures:

1. **Study the adapter requirements** in `src/lib/adapters/<format>.sh`
2. **Create minimum viable structure** that satisfies validation
3. **Keep file size small** (< 5 KB preferred)
4. **Include stub SQL** with at minimum:
   - `wp_options` table definition
   - `siteurl` and `home` option rows
5. **Test validation** using `./wp-migrate.sh --archive <file> --verbose`

### Example: Creating a Duplicator test fixture

```bash
mkdir -p test/dup-installer
echo "<?php // Stub" > test/installer.php
echo "CREATE TABLE wp_options (option_name varchar(191));" > test/dup-installer/dup-database__test.sql
cd test && zip -r duplicator-test.zip . && cd ..
```

## Maintenance

These fixtures should be regenerated if:

- Adapter validation logic changes significantly
- New required signature files are added
- Format specifications change

Current versions created: 2025-10-20

## See Also

- `src/lib/adapters/README.md` - Adapter architecture documentation
- `tests/integration/` - Integration test scripts
- `.github/workflows/test.yml` - CI/CD pipeline that runs these tests
