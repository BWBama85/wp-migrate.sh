# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
### Added
- Expanded automatic wp search-replace to cover protocol-relative, JSON-escaped, and trailing-slash variants of the domain, plus optional `--dest-domain`/`--dest-home-url`/`--dest-site-url` overrides when detection needs a hint.
- Documented the Git workflow and provided supporting templates for commits and pull requests.
- Added comprehensive test suite (`test-wp-migrate.sh`) validating argument parsing, error handling, and code quality without requiring WordPress installations.
- Added `--version` flag (short: `-v`) to display version information from git tags or CHANGELOG.md.
- Added URL format validation for `--dest-home-url` and `--dest-site-url` options to catch invalid URLs early.
- Added early SSH connectivity test to fail fast with helpful error messages when destination host is unreachable.
- Added `--info=progress2` to rsync for real-time file transfer progress indicators during database and wp-content transfers.

### Changed
- Added ShellCheck disable directives for intentional client-side expansions in SSH commands to achieve zero ShellCheck warnings.

## [Pre-history]
### Added
- `wp-migrate.sh` initial script prior to adopting the tracked changelog.
