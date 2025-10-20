# WordPress Migration Test Environment
# Provides a complete environment for testing wp-migrate.sh with actual WordPress installations

FROM wordpress:6.7-php8.3-apache

# Install required dependencies for wp-migrate.sh
RUN apt-get update && apt-get install -y \
    wget \
    curl \
    less \
    rsync \
    default-mysql-client \
    openssh-client \
    sudo \
    unzip \
    gzip \
    tar \
    && rm -rf /var/lib/apt/lists/*

# Install WP-CLI
RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x wp-cli.phar \
    && mv wp-cli.phar /usr/local/bin/wp

# Create test user with sudo access (for testing script permissions)
RUN useradd -m -s /bin/bash wptest \
    && echo "wptest ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Set up WordPress directory permissions
RUN chown -R www-data:www-data /var/www/html

# Copy wp-migrate.sh and test scripts
COPY wp-migrate.sh /usr/local/bin/wp-migrate.sh
RUN chmod +x /usr/local/bin/wp-migrate.sh

# Create directory for test fixtures and copy them
# Note: COPY with wildcards doesn't fail if no files match (unlike COPY with specific files)
RUN mkdir -p /opt/test-fixtures
COPY tests/fixtures/*.zip tests/fixtures/*.tar.gz /opt/test-fixtures/

WORKDIR /var/www/html

# Health check - verify WordPress is accessible
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
    CMD curl -f http://localhost/ || exit 1

# Keep standard WordPress entrypoint
CMD ["apache2-foreground"]
