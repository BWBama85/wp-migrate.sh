# v2.10.0 - Security & Stability Hardening

This minor release addresses critical security vulnerabilities and data loss scenarios identified during a comprehensive security audit (#89). **All critical, high-priority, and medium-priority issues have been resolved.**

## 🚨 Security Fixes (Critical)

### Zip Slip Path Traversal Protection (#81, #90)
- **CRITICAL:** Archive extraction now validates all paths to prevent malicious archives from writing files outside the extraction directory
- Prevents remote code execution via crafted archives containing paths like `../../etc/passwd`
- All adapter extraction functions now sanitize and validate paths
- Archives attempting path traversal are rejected with detailed error messages

### SQL Injection Prevention (#83, #92)
- **CRITICAL:** Table name validation added to prevent SQL injection in DROP TABLE operations
- Table names must match WordPress naming pattern: `{prefix}_{tablename}` or `{prefix}{number}_{tablename}` (multisite)
- Prevents malicious table names from executing arbitrary SQL
- Invalid table names are rejected with detailed error messages

### Emergency Database Snapshot (#82, #91)
- **CRITICAL:** Database reset now creates emergency snapshot before dropping tables
- Automatic rollback if import fails or produces zero tables
- Snapshot automatically restored on script exit if needed
- Prevents permanent database loss from crashes during reset
- Temporary snapshot cleaned up after successful migration

## 🛡️ Data Protection Fixes (Critical)

### Multi-WordPress Database Detection (#84, #93)
- **CRITICAL:** Script now detects and prevents ambiguous migrations when multiple WordPress installations share a database
- Prevents importing from wrong WordPress installation
- Users must confirm which installation to use
- Clear error messages with instructions for single-site migration

### wp-content Backup Verification (#85, #94)
- **CRITICAL:** Backup operations are now validated before proceeding with destructive changes
- Verifies backup directory exists and is not empty
- Checks backup size matches source (within 10% tolerance)
- Prevents data loss from failed backup operations
- Detailed error messages with filesystem diagnostics

### Dry-run Mode Crash Fixes (#86, #95)
- **CRITICAL:** Dry-run mode no longer crashes when preview logic attempts file operations
- All file stat and size operations check $DRY_RUN flag first
- Dry-run mode now fully functional for testing migrations
- Provides accurate preview without touching filesystem

## ⚡ High-Priority Improvements (Issue #87, PR #96)

- **Resource leak fixes**: Temporary extraction directories are now cleaned up in all exit paths
- **Database import verification**: Import success is validated by checking table count
- **Rollback safety improvements**: Rollback operations now validate both restore and revert operations
- **Adapter validation**: ARCHIVE_ADAPTER variable is validated before use
- **Foreign key constraint handling**: Database import now temporarily disables foreign key checks
- **Emergency snapshot error messages**: Error messages now accurately describe automatic vs manual recovery

## 📦 Code Quality Improvements (Issue #88, PRs #97 & #98)

- **SQL consolidation deduplication**: Eliminated ~90 lines of duplicate code
- **Adapter detection error reporting**: Removed stderr suppression to improve troubleshooting
- **Pipefail state management**: Added trap-based restoration to prevent state leakage
- **Directory search optimization**: Dramatically improves performance on large archives
- **wp-content path validation**: Comprehensive validation with detailed error messages
- **Error message simplification**: Shows only relevant format information
- **Array difference documentation**: Clarified space handling in array operations
- **Log file rotation**: Automatic cleanup keeps only 20 most recent log files
- **URL consistency verification**: Samples post content for mismatched URLs

## 🔧 Developer Notes

- All fixes maintain **backward compatibility**
- No changes to command-line interface or behavior
- Existing scripts and workflows continue to work unchanged
- Security improvements are transparent to users

## ⚠️ Upgrade Recommendations

**Immediate upgrade recommended** for all users due to critical security fixes:

- **Zip Slip vulnerability** (CVE pending) allows arbitrary file writes - upgrade before processing untrusted archives
- **Emergency snapshot feature** provides automatic recovery - highly recommended for production migrations
- All existing functionality preserved - **safe drop-in replacement**

## 📊 Release Scope

- **9 merged PRs** (#90-#98)
- **6 critical vulnerabilities** fixed
- **7 high-priority improvements** completed
- **9 code quality enhancements** implemented
- **59 unique issues** from security audit addressed

## 🙏 Acknowledgments

Thanks to the security audit team for thorough and independent review. The competition format encouraged comprehensive analysis and caught issues that might have been missed in standard review.

---

**Full Changelog**: https://github.com/BWBama85/wp-migrate.sh/compare/v2.9.0...v2.10.0
