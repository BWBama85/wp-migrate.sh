.PHONY: build test clean help

# Default target
all: build

help:
	@echo "wp-migrate.sh build system"
	@echo ""
	@echo "Targets:"
	@echo "  build   - Build dist/wp-migrate.sh from modular source"
	@echo "  test    - Run shellcheck on all source files"
	@echo "  clean   - Remove dist/ directory"
	@echo "  help    - Show this help message"

# Run shellcheck on built file (not individual modules, to avoid false "unused variable" warnings)
test:
	@echo "Building temporary file for shellcheck..."
	@mkdir -p dist
	@cat src/header.sh \
	     src/lib/core.sh \
	     src/lib/functions.sh \
	     src/main.sh > dist/wp-migrate-temp.sh
	@echo "Running shellcheck on complete script..."
	@shellcheck dist/wp-migrate-temp.sh
	@rm dist/wp-migrate-temp.sh
	@echo "✓ Shellcheck passed"

# Build the single-file script
build: test
	@echo "Building wp-migrate.sh..."
	@mkdir -p dist
	@cat src/header.sh \
	     src/lib/core.sh \
	     src/lib/functions.sh \
	     src/main.sh > dist/wp-migrate.sh
	@chmod +x dist/wp-migrate.sh
	@cp dist/wp-migrate.sh ./wp-migrate.sh
	@echo "✓ Built: dist/wp-migrate.sh"
	@echo "✓ Copied: ./wp-migrate.sh (repo root)"
	@shasum -a 256 wp-migrate.sh > wp-migrate.sh.sha256
	@echo "✓ Checksum: wp-migrate.sh.sha256"
	@echo ""
	@echo "Build complete! Users can download:"
	@echo "  curl -O https://raw.githubusercontent.com/BWBama85/wp-migrate.sh/main/wp-migrate.sh"

# Clean build artifacts
clean:
	@rm -rf dist/
	@echo "✓ Cleaned dist/"
