# GitHub Actions Workflows

This directory contains CI/CD workflows for automated testing and validation.

## Workflows

### test.yml - Comprehensive Test Suite

Runs on every push and pull request to main/develop branches.

#### Test Jobs:

1. **ShellCheck Linting**
   - Validates shell script syntax and best practices
   - Uses `make test` to build and lint
   - Verifies built script exists and is up to date

2. **Unit Tests**
   - Runs test-wp-migrate.sh test suite
   - Validates help and version output
   - Checks script permissions

3. **Bash Compatibility** (Matrix)
   - Tests across Bash versions: 3.2, 4.0, 4.4, 5.0, 5.1
   - Uses Docker containers for version isolation
   - Validates syntax and help output

4. **Build Validation**
   - Rebuilds from source and compares to committed version
   - Ensures source files and built script are in sync
   - Catches commits that modify src/ without rebuilding

5. **Security Scan**
   - Scans for hardcoded secrets/credentials
   - Checks for unsafe bash practices (eval, curl|bash)
   - Validates secure coding patterns

6. **macOS Compatibility**
   - Tests on latest macOS runner
   - Validates BSD tool compatibility (stat, etc.)
   - Runs full test suite on macOS

7. **Documentation Check**
   - Verifies CHANGELOG.md is updated in PRs
   - Checks for broken markdown links
   - Validates README has usage examples

8. **Integration Smoke Test**
   - Installs WP-CLI
   - Tests dry-run modes (push and archive)
   - Validates error messages and graceful failures

## Status Badge

Add this to your README.md to show build status:

```markdown
![Tests](https://github.com/BWBama85/wp-migrate.sh/workflows/Tests/badge.svg)
```

## Running Locally

To run the same checks locally before pushing:

```bash
# ShellCheck
make test

# Unit tests
./test-wp-migrate.sh

# Build validation
make clean && make build

# Security scan (manual)
grep -r "password.*=" src/

# Test multiple Bash versions with Docker
docker run --rm -v "$PWD:/workspace" -w /workspace bash:3.2 bash -n wp-migrate.sh
docker run --rm -v "$PWD:/workspace" -w /workspace bash:4.0 bash -n wp-migrate.sh
docker run --rm -v "$PWD:/workspace" -w /workspace bash:5.1 bash -n wp-migrate.sh
```

## Workflow Triggers

The test workflow runs on:
- Push to: main, develop, feature/*, fix/* branches
- Pull requests to: main, develop

## Failure Handling

If any critical job fails, the summary job will fail, preventing merge.

Jobs that only warn (non-blocking):
- Documentation checks (CHANGELOG updates)
- Some security scans (eval usage warnings)

## Adding New Tests

To add new test jobs:

1. Add job to `.github/workflows/test.yml`
2. Add job to `needs` list in `summary` job
3. Update this README
4. Test workflow with a draft PR

## Maintenance

- Review workflow runs weekly for flaky tests
- Update Bash version matrix when new versions release
- Keep actions updated (dependabot recommended)
