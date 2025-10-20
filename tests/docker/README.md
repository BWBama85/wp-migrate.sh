# Docker Integration Test Environment

Complete Docker-based testing environment for `wp-migrate.sh` with real WordPress + MySQL instances.

## Overview

This Docker environment provides:

- **Two WordPress instances**: Source and destination for testing migrations
- **Two MySQL databases**: Isolated databases for each WordPress instance
- **All dependencies**: WP-CLI, rsync, SSH, and all tools needed by wp-migrate.sh
- **Test fixtures**: Pre-loaded minimal backup archives for testing
- **Automated test suite**: Integration tests covering archive imports and environment verification

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Docker Test Environment                   │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌─────────────────────┐      ┌─────────────────────┐      │
│  │   Source WordPress   │      │   Dest WordPress    │      │
│  │   localhost:8080     │      │   localhost:8081    │      │
│  │                      │      │                     │      │
│  │ - WordPress 6.7      │      │ - WordPress 6.7     │      │
│  │ - PHP 8.3            │      │ - PHP 8.3           │      │
│  │ - WP-CLI             │      │ - WP-CLI            │      │
│  │ - wp-migrate.sh      │      │ - wp-migrate.sh     │      │
│  └──────────┬───────────┘      └──────────┬──────────┘      │
│             │                             │                  │
│             ▼                             ▼                  │
│  ┌─────────────────────┐      ┌─────────────────────┐      │
│  │   source-db (MySQL)  │      │   dest-db (MySQL)   │      │
│  │                      │      │                     │      │
│  │ - wordpress_source   │      │ - wordpress_dest    │      │
│  │ - wpuser / wppass    │      │ - wpuser / wppass   │      │
│  └─────────────────────┘      └─────────────────────┘      │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

## Requirements

- Docker (20.10+)
- Docker Compose (2.0+)
- At least 2GB free RAM
- At least 2GB free disk space

## Quick Start

### Run All Tests

```bash
# From repository root
cd tests/docker
./run-tests.sh
```

This will:
1. Build Docker images
2. Start all containers
3. Install WordPress in both instances
4. Add test content to source
5. Run integration tests
6. Clean up containers

### Manual Testing

```bash
# Start containers
cd tests/docker
docker-compose up -d

# Wait for WordPress environment to be ready (WP-CLI + DB, takes ~30s)
# This checks database connectivity, not whether WordPress is installed
docker-compose exec source-wp wp db check --allow-root

# Install WordPress manually if needed
docker-compose exec source-wp bash -c "
  cd /var/www/html && \
  wp core install \
    --url='http://localhost:8080' \
    --title='Source Site' \
    --admin_user=admin \
    --admin_password=admin \
    --admin_email=admin@example.com \
    --allow-root
"

# Test archive import on destination
docker-compose exec dest-wp bash -c "
  cd /var/www/html && \
  wp-migrate.sh --archive /opt/test-fixtures/duplicator-minimal.zip --dry-run --verbose
"

# Access WordPress admin
# Source: http://localhost:8080/wp-admin (admin/admin)
# Dest:   http://localhost:8081/wp-admin (admin/admin)

# Stop and remove containers
docker-compose down -v
```

## Test Suite

The test runner (`run-tests.sh`) performs these tests:

1. **Archive Mode - Duplicator Format**: Verifies Duplicator archive detection
2. **Archive Mode - Jetpack Format**: Verifies Jetpack archive detection
3. **Archive Mode - Solid Backups Format**: Verifies Solid Backups archive detection
4. **WordPress Environment**: Verifies test content exists in source
5. **WP-CLI Availability**: Verifies WP-CLI works in both containers
6. **Script Availability**: Verifies wp-migrate.sh is accessible

### Expected Output

```
Docker Integration Test Suite
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Starting Docker containers...
Waiting for containers to be healthy...

Test: Archive Mode - Duplicator format import
✓ Duplicator archive detected in dry-run mode

Test: Archive Mode - Jetpack format import
✓ Jetpack archive detected in dry-run mode

Test: Archive Mode - Solid Backups format import
✓ Solid Backups archive detected in dry-run mode

Test: WordPress environment verification
✓ Source WordPress has test posts
✓ Destination WordPress is installed

Test: WP-CLI availability in containers
✓ WP-CLI available in source container
✓ WP-CLI available in dest container

Test: wp-migrate.sh script availability
✓ wp-migrate.sh available in source container
✓ wp-migrate.sh available in dest container

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Test Summary: 9 run, 9 passed, 0 failed
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Container Details

### Source WordPress (source-wp)

- **URL**: http://localhost:8080
- **Database**: wordpress_source on source-db
- **Admin**: admin / admin
- **Purpose**: Test migrations FROM this instance
- **Test Data**: 2 sample posts with content

### Destination WordPress (dest-wp)

- **URL**: http://localhost:8081
- **Database**: wordpress_dest on dest-db
- **Admin**: admin / admin
- **Purpose**: Test migrations TO this instance
- **Test Archives**: Available at `/opt/test-fixtures/`

### Test Fixtures

All test archives from `tests/fixtures/` are mounted at `/opt/test-fixtures/`:

- `duplicator-minimal.zip` (1.9 KB)
- `jetpack-minimal.tar.gz` (1.1 KB)
- `solidbackups-minimal.zip` (2.0 KB)

## Useful Commands

```bash
# View logs
docker-compose logs -f source-wp
docker-compose logs -f dest-wp

# Execute commands in containers
docker-compose exec source-wp bash
docker-compose exec dest-wp bash

# Run WP-CLI commands
docker-compose exec source-wp wp --info --allow-root
docker-compose exec dest-wp wp post list --allow-root

# Check database
docker-compose exec source-db mysql -u wpuser -pwppass wordpress_source

# Rebuild containers
docker-compose down -v
docker-compose up -d --build

# Check container health
docker-compose ps
```

## Troubleshooting

### Containers won't start

```bash
# Check Docker daemon is running
docker ps

# Check for port conflicts
lsof -i :8080
lsof -i :8081

# View container logs
docker-compose logs
```

### WordPress installation fails

```bash
# Check database connectivity
docker-compose exec source-wp wp db check --allow-root

# Manually install
docker-compose exec source-wp bash
cd /var/www/html
wp core install --url='http://localhost:8080' --title='Test' \
  --admin_user=admin --admin_password=admin \
  --admin_email=admin@example.com --allow-root
```

### wp-migrate.sh not found

```bash
# Verify mount
docker-compose exec source-wp ls -la /usr/local/bin/wp-migrate.sh

# Rebuild if needed
docker-compose down
docker-compose up -d --build
```

### Tests fail intermittently

```bash
# Increase wait time for WordPress readiness
# Edit run-tests.sh, increase max_wait value

# Or add manual wait
docker-compose up -d
sleep 60  # Wait longer before running tests
./run-tests.sh
```

## CI/CD Integration

This Docker environment is used in GitHub Actions CI/CD pipeline:

```yaml
- name: Run Docker integration tests
  run: |
    cd tests/docker
    ./run-tests.sh
```

The tests run on every push and pull request to verify:
- Archive format detection works end-to-end
- WordPress environment compatibility
- WP-CLI integration

## Development Workflow

### Testing Local Changes

1. Make changes to `wp-migrate.sh`
2. Run Docker tests: `cd tests/docker && ./run-tests.sh`
3. Tests automatically use your local script (via volume mount)
4. Iterate until tests pass

### Adding New Tests

Edit `run-tests.sh` to add new test cases:

```bash
test_header "Your new test description"

if docker-compose exec -T dest-wp bash -c "
  # Your test commands here
"; then
  pass "Test passed message"
else
  fail "Test failed message"
fi
```

### Testing Specific Scenarios

```bash
# Start environment
docker-compose up -d
sleep 30

# Run your custom test
docker-compose exec -T source-wp bash -c "
  cd /var/www/html && \
  # Your test commands
"

# Clean up
docker-compose down -v
```

## Performance

- **Startup time**: ~30-40 seconds (first build ~2-3 minutes)
- **Test execution**: ~10-15 seconds
- **Total runtime**: ~1 minute
- **Disk usage**: ~1.5 GB (images + volumes)
- **Memory usage**: ~800 MB

## Limitations

- **No SSH testing**: Push mode requires SSH between containers (not yet implemented)
- **Dry-run only**: Current tests only verify dry-run mode for archive imports
- **Minimal test data**: Test archives are minimal stubs, not full WordPress sites
- **Local only**: Docker environment is for local testing, not production use

## Future Enhancements

- [ ] SSH configuration between source and dest containers for push mode testing
- [ ] Full migration tests (not just dry-run)
- [ ] Database content verification after migrations
- [ ] Search-replace validation
- [ ] Performance benchmarking
- [ ] Multi-site testing
- [ ] Custom table prefix testing

## See Also

- [Test Fixtures Documentation](../fixtures/README.md)
- [Integration Test Suite](../integration/)
- [CI/CD Workflow](../../.github/workflows/test.yml)
