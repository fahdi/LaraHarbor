#!/bin/bash

# LaraHarbor: Laravel Multi-Site Setup System
# Allows multiple Laravel sites to run concurrently, each with its own .local domain

# ----- Initial Setup (Run once) -----
setup_system() {
  echo "Setting up LaraHarbor multi-site system..."
  
  # Create main directory structure
  mkdir -p ~/LaraHarbor/proxy
  mkdir -p ~/LaraHarbor/mailhog
  mkdir -p ~/LaraHarbor/backups
  cd ~/LaraHarbor
  
  # Create Docker network for all sites
  docker network create laraharbor-network 2>/dev/null || true
  
  # Create docker-compose for proxy with SSL support for .local domains
  cat > ~/LaraHarbor/proxy/docker-compose.yml << 'EOF'
services:
  nginx-proxy:
    image: jwilder/nginx-proxy:alpine
    container_name: laraharbor-proxy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/tmp/docker.sock:ro
      - ./certs:/etc/nginx/certs
      - ./vhost.d:/etc/nginx/vhost.d
      - ./html:/usr/share/nginx/html
      - ./conf.d:/etc/nginx/conf.d
    restart: unless-stopped
    networks:
      - proxy-network

networks:
  proxy-network:
    external: true
    name: laraharbor-network
EOF

  # Set up MailHog mail catcher
  cat > ~/LaraHarbor/mailhog/docker-compose.yml << 'EOF'
services:
  mailhog:
    image: mailhog/mailhog
    container_name: laraharbor-mailhog
    environment:
      - VIRTUAL_HOST=mail.local
      - VIRTUAL_PORT=8025
      - VIRTUAL_PROTO=http
      - HTTPS_METHOD=redirect
    networks:
      - mailhog-network

networks:
  mailhog-network:
    external: true
    name: laraharbor-network
EOF

  # Set up backup system scheduler
  cat > ~/LaraHarbor/backups/docker-compose.yml << 'EOF'
version: '3'

services:
  backup-scheduler:
    image: mcuadros/ofelia:latest
    container_name: laraharbor-backup-scheduler
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./config.ini:/etc/ofelia/config.ini
      - ../:/sites:ro
      - ./:/backups
    restart: unless-stopped
    networks:
      - backup-network

networks:
  backup-network:
    external: true
    name: laraharbor-network
EOF

  # Create scheduler configuration file
  cat > ~/LaraHarbor/backups/config.ini << 'EOF'
[global]
# Backup schedule configuration

[job-exec "backup-all-sites"]
schedule = @daily
container = laraharbor-backup-scheduler
command = /bin/sh -c "cd /backups && ./backup-all-sites.sh"
EOF

  # Create backup script for all sites
  cat > ~/LaraHarbor/backups/backup-all-sites.sh << 'EOF'
#!/bin/bash

BACKUP_ROOT="/backups"
DATE=$(date +"%Y-%m-%d")
echo "Starting backup of all Laravel sites at $(date)"

# Find all Laravel sites
for site_dir in /sites/*/; do
  if [ -f "${site_dir}docker-compose.yml" ]; then
    site_name=$(basename "${site_dir}")
    
    # Skip proxy and mailhog directories
    if [[ "$site_name" != "proxy" && "$site_name" != "mailhog" && "$site_name" != "backups" ]]; then
      echo "Backing up site: $site_name"
      
      # Create backup directory for site
      mkdir -p "${BACKUP_ROOT}/${site_name}"
      
      # Get database connection info from .env file
      if [ -f "${site_dir}src/.env" ]; then
        DB_USERNAME=$(grep DB_USERNAME "${site_dir}src/.env" | cut -d '=' -f2)
        DB_PASSWORD=$(grep DB_PASSWORD "${site_dir}src/.env" | cut -d '=' -f2)
        DB_DATABASE=$(grep DB_DATABASE "${site_dir}src/.env" | cut -d '=' -f2)
        DB_CONNECTION=$(grep DB_CONNECTION "${site_dir}src/.env" | cut -d '=' -f2)
      else
        DB_USERNAME="laravel"
        DB_PASSWORD="laravel"
        DB_DATABASE="laravel"
        DB_CONNECTION="mysql"
      fi
      
      # Create backup of database - only if container is running
      if docker ps --format '{{.Names}}' | grep -q "${site_name}-db"; then
        echo "  - Backing up database..."
        
        if [[ "$DB_CONNECTION" == "pgsql" ]]; then
          # PostgreSQL backup
          docker exec "${site_name}-db" pg_dump -U "${DB_USERNAME}" "${DB_DATABASE}" > "${BACKUP_ROOT}/${site_name}/${DATE}-${site_name}-db.sql"
        else
          # MySQL backup (default)
          docker exec "${site_name}-db" mysqldump -u "${DB_USERNAME}" -p"${DB_PASSWORD}" "${DB_DATABASE}" > "${BACKUP_ROOT}/${site_name}/${DATE}-${site_name}-db.sql"
        fi
        
        echo "  ✅ Backup completed for $site_name"
      else
        echo "  ⚠️ Database container not running for $site_name, skipping backup"
      fi
    fi
  fi
done

echo "Backup process completed at $(date)"

# Cleanup old backups (keep last 7 days)
echo "Cleaning up old backups..."
find "${BACKUP_ROOT}" -type f -name "*.sql" -mtime +7 -delete

echo "All operations completed successfully"
EOF

  # Make the script executable
  chmod +x ~/LaraHarbor/backups/backup-all-sites.sh

  # Create directories
  mkdir -p ~/LaraHarbor/proxy/{certs,vhost.d,html,conf.d}
  
  # Create default SSL configuration
  cat > ~/LaraHarbor/proxy/conf.d/default.conf << 'EOF'
# Default SSL configuration
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers HIGH:!aNULL:!MD5;
ssl_prefer_server_ciphers on;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 10m;
EOF

  # Create uploads configuration to increase file size limits
  cat > ~/LaraHarbor/proxy/conf.d/uploads.conf << 'EOF'
# Increase upload size limits
client_max_body_size 128M;
EOF

  # Start proxy
  cd ~/LaraHarbor/proxy
  docker compose up -d
  
  # Generate SSL cert for mail.local
  generate_ssl_cert "mail.local"
  
  # Add mail.local to hosts file
  if ! grep -q "mail.local" /etc/hosts; then
    sudo bash -c "echo '127.0.0.1 mail.local' >> /etc/hosts"
  fi
  
  # Start mailhog and backup scheduler
  cd ~/LaraHarbor/mailhog
  docker compose up -d
  
  cd ~/LaraHarbor/backups
  docker compose up -d
  
  echo "✅ LaraHarbor proxy system, MailHog, and backup system set up successfully!"
  echo "📧 Mail catcher UI available at: https://mail.local"
  echo "💾 Automated daily backups enabled"
}

# Generate self-signed SSL certificate for a domain
generate_ssl_cert() {
  local domain=$1
  local cert_dir=~/LaraHarbor/proxy/certs
  
  echo "Generating self-signed SSL certificate for ${domain}..."
  
  # Generate SSL certificate
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout ${cert_dir}/${domain}.key \
    -out ${cert_dir}/${domain}.crt \
    -subj "/CN=${domain}/O=LaraHarbor/C=US" \
    -addext "subjectAltName=DNS:${domain},DNS:*.${domain}"
  
  # Create bundle file for Nginx proxy
  cat ${cert_dir}/${domain}.crt ${cert_dir}/${domain}.key > ${cert_dir}/${domain}.pem
  
  echo "✅ SSL certificate generated for ${domain}"
}

# ----- Create New Laravel Site -----
create_site() {
  # Get site name
  read -p "Enter site name (e.g., mysite): " SITE_NAME
  
  if [[ -z "$SITE_NAME" ]]; then
    echo "❌ Site name cannot be empty."
    exit 1
  fi
  
  # Clean site name
  SITE_NAME=$(echo "$SITE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  SITE_DOMAIN="${SITE_NAME}.local"
  SITE_DIR=~/LaraHarbor/${SITE_NAME}
  
  # Check if site exists
  if [ -d "$SITE_DIR" ]; then
    echo "❌ Site already exists: $SITE_DIR"
    exit 1
  fi
  
  # Choose database type
  echo "Choose database type:"
  echo "1. MySQL (recommended)"
  echo "2. PostgreSQL"
  read -p "Enter choice [1]: " DB_TYPE_CHOICE
  
  # Set database type and default settings
  if [[ "$DB_TYPE_CHOICE" == "2" ]]; then
    DB_TYPE="pgsql"
    DB_IMAGE="postgres:14"
    DB_PORT="5432"
    DB_ENV_PREFIX="POSTGRES"
    DB_ROOT_USER="postgres"
  else
    DB_TYPE="mysql"
    DB_IMAGE="mysql:8.0"
    DB_PORT="3306"
    DB_ENV_PREFIX="MYSQL"
    DB_ROOT_USER="root"
  fi
  
  # Use Redis?
  read -p "Include Redis for caching? (y/n) [y]: " REDIS_CHOICE
  REDIS_CHOICE=${REDIS_CHOICE:-y}
  
  # Create Laravel version choice
  echo "Choose Laravel installation method:"
  echo "1. Use latest Laravel version (via Composer)"
  echo "2. Import existing Laravel project (from Git)"
  read -p "Enter choice [1]: " LARAVEL_CHOICE
  LARAVEL_CHOICE=${LARAVEL_CHOICE:-1}
  
  # Create site directory structure
  mkdir -p $SITE_DIR/{src,database,logs}
  cd $SITE_DIR
  
  # Generate random passwords
  DB_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  DB_ROOT_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  REDIS_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
  
  # Generate SSL certificate for the domain
  generate_ssl_cert $SITE_DOMAIN
  generate_ssl_cert admin.$SITE_DOMAIN
  
  # Create custom PHP configuration
  mkdir -p $SITE_DIR/php-config
  cat > $SITE_DIR/php-config/custom.ini << 'EOF'
; Custom PHP settings for Laravel
upload_max_filesize = 128M
post_max_size = 128M
memory_limit = 256M
max_execution_time = 300
max_input_time = 300
display_errors = On
error_reporting = E_ALL
EOF
  
  # Create docker-compose.yml
  cat > docker-compose.yml << EOF
services:
  ${SITE_NAME}-app:
    image: ${SITE_NAME}-app
    container_name: ${SITE_NAME}-app
    build:
      context: ./docker
    volumes:
      - ./src:/var/www/html
      - ./php-config/custom.ini:/usr/local/etc/php/conf.d/custom.ini
    depends_on:
      - ${SITE_NAME}-db
EOF

  # Add Redis if selected
  if [[ "$REDIS_CHOICE" == "y" ]]; then
    cat >> docker-compose.yml << EOF
      - ${SITE_NAME}-redis
EOF
  fi
  
  cat >> docker-compose.yml << EOF
    environment:
      - VIRTUAL_HOST=${SITE_DOMAIN}
      - VIRTUAL_PORT=80
      - VIRTUAL_PROTO=http
      - HTTPS_METHOD=redirect
    networks:
      - laraharbor-network
      - internal
    restart: unless-stopped
  
  ${SITE_NAME}-db:
    image: ${DB_IMAGE}
    container_name: ${SITE_NAME}-db
    volumes:
      - ./database:/var/lib/${DB_TYPE == "pgsql" ? "postgresql/data" : "mysql"}
    environment:
EOF

  # Add database environment variables based on type
  if [[ "$DB_TYPE" == "pgsql" ]]; then
    cat >> docker-compose.yml << EOF
      - POSTGRES_USER=laravel
      - POSTGRES_PASSWORD=${DB_PASSWORD}
      - POSTGRES_DB=laravel
EOF
  else
    cat >> docker-compose.yml << EOF
      - MYSQL_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
      - MYSQL_DATABASE=laravel
      - MYSQL_USER=laravel
      - MYSQL_PASSWORD=${DB_PASSWORD}
EOF
  fi
  
  cat >> docker-compose.yml << EOF
    networks:
      - internal
    restart: unless-stopped
EOF

  # Add Redis if selected
  if [[ "$REDIS_CHOICE" == "y" ]]; then
    cat >> docker-compose.yml << EOF
  
  ${SITE_NAME}-redis:
    image: redis:alpine
    container_name: ${SITE_NAME}-redis
    command: redis-server --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis-data:/data
    networks:
      - internal
    restart: unless-stopped
EOF
  fi

  # Add database admin tool
  if [[ "$DB_TYPE" == "pgsql" ]]; then
    cat >> docker-compose.yml << EOF
  
  ${SITE_NAME}-dbadmin:
    image: adminer
    container_name: ${SITE_NAME}-dbadmin
    depends_on:
      - ${SITE_NAME}-db
    environment:
      - ADMINER_DEFAULT_SERVER=${SITE_NAME}-db
      - VIRTUAL_HOST=admin.${SITE_DOMAIN}
      - VIRTUAL_PORT=8080
      - VIRTUAL_PROTO=http
      - HTTPS_METHOD=redirect
    networks:
      - internal
      - laraharbor-network
    restart: unless-stopped
EOF
  else
    cat >> docker-compose.yml << EOF
  
  ${SITE_NAME}-dbadmin:
    image: phpmyadmin/phpmyadmin
    container_name: ${SITE_NAME}-dbadmin
    depends_on:
      - ${SITE_NAME}-db
    environment:
      - PMA_HOST=${SITE_NAME}-db
      - PMA_USER=root
      - PMA_PASSWORD=${DB_ROOT_PASSWORD}
      - VIRTUAL_HOST=admin.${SITE_DOMAIN}
      - VIRTUAL_PORT=80
      - VIRTUAL_PROTO=http
      - HTTPS_METHOD=redirect
      - UPLOAD_LIMIT=128M
    networks:
      - internal
      - laraharbor-network
    restart: unless-stopped
EOF
  fi

  # Add networks and volumes
  cat >> docker-compose.yml << EOF

networks:
  laraharbor-network:
    external: true
    name: laraharbor-network
  internal:
    driver: bridge
EOF

  # Add Redis volume if selected
  if [[ "$REDIS_CHOICE" == "y" ]]; then
    cat >> docker-compose.yml << EOF

volumes:
  redis-data:
EOF
  fi

  # Create Docker directory for application Dockerfile
  mkdir -p $SITE_DIR/docker
  
  # Create Dockerfile for Laravel application
  cat > $SITE_DIR/docker/Dockerfile << 'EOF'
FROM php:8.2-fpm

# Install dependencies
RUN apt-get update && apt-get install -y \
    libpng-dev \
    libonig-dev \
    libxml2-dev \
    libzip-dev \
    zip \
    unzip \
    git \
    curl \
    nginx \
    supervisor \
    netcat-openbsd

# Clear cache
RUN apt-get clean && rm -rf /var/lib/apt/lists/*

# Install PHP extensions
RUN docker-php-ext-install pdo pdo_mysql mbstring exif pcntl bcmath gd zip

# Install Redis extension
RUN pecl install redis && docker-php-ext-enable redis

# Get latest Composer
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Configure Nginx
COPY nginx.conf /etc/nginx/sites-available/default
RUN ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log

# Configure supervisord
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Create system user to run Composer and Artisan Commands
RUN useradd -G www-data,root -u 1000 -d /home/laravel laravel
RUN mkdir -p /home/laravel/.composer && \
    chown -R laravel:laravel /home/laravel

# Set working directory
WORKDIR /var/www/html

# Copy project files
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

# Add docker host IP to environment variables for mailer testing with mailhog
ENV MAIL_HOST=laraharbor-mailhog
ENV MAIL_PORT=1025

# Start server
CMD ["/usr/local/bin/start.sh"]

EXPOSE 80
EOF

  # Create Nginx configuration for Laravel
  cat > $SITE_DIR/docker/nginx.conf << 'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/html/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php;

    charset utf-8;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

  # Create supervisord configuration
  cat > $SITE_DIR/docker/supervisord.conf << 'EOF'
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

[program:php-fpm]
command=/usr/local/sbin/php-fpm
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

  # Create startup script
  cat > $SITE_DIR/docker/start.sh << 'EOF'
#!/bin/bash

# Check if we need to run Composer commands
if [ ! -d "/var/www/html/vendor" ]; then
    echo "Running composer install..."
    composer install --no-interaction --no-progress
fi

# Check if .env file exists
if [ ! -f "/var/www/html/.env" ]; then
    echo "Creating .env file..."
    cp .env.example .env
    
    # Generate application key
    php artisan key:generate
fi

# Make sure Redis extension is available if needed
if grep -q "REDIS_HOST" /var/www/html/.env; then
    if ! php -m | grep -q "redis"; then
        echo "Installing Redis extension..."
        pecl install redis && docker-php-ext-enable redis
    fi
fi

# Wait for database to be ready
echo "Waiting for database to be ready..."
until nc -z -v -w30 $(grep DB_HOST /var/www/html/.env | cut -d '=' -f2) 3306
do
  echo "Waiting for database connection..."
  sleep 5
done

# Apply database migrations
echo "Running database migrations..."
php artisan migrate --force

# Clear caches
php artisan config:clear
php artisan cache:clear
php artisan view:clear
php artisan route:clear

# Set proper permissions
chown -R www-data:www-data /var/www/html/storage
chown -R www-data:www-data /var/www/html/bootstrap/cache

# Start supervisord
/usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
EOF

  # Create an .env file with environment variables
  cat > .env << EOF
SITE_NAME=${SITE_NAME}
SITE_DOMAIN=${SITE_DOMAIN}
DB_TYPE=${DB_TYPE}
DB_PASSWORD=${DB_PASSWORD}
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
EOF

  # Update hosts file
  echo "Updating /etc/hosts file with ${SITE_DOMAIN}..."
  if ! grep -q "${SITE_DOMAIN}" /etc/hosts; then
    sudo bash -c "echo '127.0.0.1 ${SITE_DOMAIN} admin.${SITE_DOMAIN}' >> /etc/hosts"
  fi
  
  # Create a README file with site information
  cat > README.md << EOF
# LaraHarbor Site: ${SITE_NAME}

## Site Information
- URL: https://${SITE_DOMAIN}
- Database Admin: https://admin.${SITE_DOMAIN}
- Mail Catcher: https://mail.local

## Directory Structure
- /src: Laravel application files
- /database: ${DB_TYPE == "pgsql" ? "PostgreSQL" : "MySQL"} database files
- /logs: Log files
- /docker: Docker configuration files

## Credentials
### Database
- Database Name: laravel
- Username: laravel
- Password: ${DB_PASSWORD}
- Database Host: ${SITE_NAME}-db

### Database Admin (${DB_TYPE == "pgsql" ? "Adminer" : "phpMyAdmin"})
- Username: ${DB_ROOT_USER}
- Password: ${DB_ROOT_PASSWORD}

### Redis (${REDIS_CHOICE == "y" ? "Enabled" : "Disabled"})
${REDIS_CHOICE == "y" ? "- Password: ${REDIS_PASSWORD}" : ""}

## Laravel Configuration
- PHP Version: 8.2
- Composer: Latest version
- Node.js: Not included (use host system Node.js)

## Commands
- Start site: docker compose up -d
- Stop site: docker compose down
- View logs: docker compose logs -f
- Laravel Artisan: ./artisan

## Backup Information
- Automatic daily backups are enabled
- Backup files are stored in ~/LaraHarbor/backups/${SITE_NAME}/
EOF

  # Create Laravel project or set up for existing project
  if [[ "$LARAVEL_CHOICE" == "1" ]]; then
    # Set up for new Laravel project
    echo "Setting up new Laravel project..."
    docker run --rm -v "$SITE_DIR/src:/app" composer create-project laravel/laravel /app
    
    # Install predis if Redis is selected
    if [[ "$REDIS_CHOICE" == "y" ]]; then
      docker run --rm -v "$SITE_DIR/src:/app" -w /app composer require predis/predis
    fi
    
    # Configure environment for Laravel
    cat > $SITE_DIR/src/.env << EOF
APP_NAME=${SITE_NAME}
APP_ENV=local
APP_KEY=
APP_DEBUG=true
APP_URL=https://${SITE_DOMAIN}

LOG_CHANNEL=stack
LOG_DEPRECATIONS_CHANNEL=null
LOG_LEVEL=debug

DB_CONNECTION=${DB_TYPE}
DB_HOST=${SITE_NAME}-db
DB_PORT=${DB_PORT}
DB_DATABASE=laravel
DB_USERNAME=laravel
DB_PASSWORD=${DB_PASSWORD}

BROADCAST_DRIVER=log
CACHE_DRIVER=$([ "$REDIS_CHOICE" == "y" ] && echo "redis" || echo "file")
FILESYSTEM_DISK=local
QUEUE_CONNECTION=$([ "$REDIS_CHOICE" == "y" ] && echo "redis" || echo "sync")
SESSION_DRIVER=$([ "$REDIS_CHOICE" == "y" ] && echo "redis" || echo "file")
SESSION_LIFETIME=120

$([ "$REDIS_CHOICE" == "y" ] && echo "REDIS_HOST=${SITE_NAME}-redis")
$([ "$REDIS_CHOICE" == "y" ] && echo "REDIS_PASSWORD=${REDIS_PASSWORD}")
$([ "$REDIS_CHOICE" == "y" ] && echo "REDIS_PORT=6379")

MAIL_MAILER=smtp
MAIL_HOST=laraharbor-mailhog
MAIL_PORT=1025
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_ENCRYPTION=null
MAIL_FROM_ADDRESS="hello@${SITE_DOMAIN}"
MAIL_FROM_NAME="${SITE_NAME}"
EOF

    # Set proper permissions
    chmod -R 777 $SITE_DIR/src/storage
    chmod -R 777 $SITE_DIR/src/bootstrap/cache
  else
    # Set up for existing project (user will need to import code)
    mkdir -p $SITE_DIR/src
    echo "Please import your existing Laravel project files into: $SITE_DIR/src"
    echo "Then update the .env file with the database configuration."
  fi
  
  # Create a helper script for Artisan
  cat > $SITE_DIR/artisan << EOF
#!/bin/bash
docker exec -it ${SITE_NAME}-app php artisan "\$@"
EOF
  chmod +x $SITE_DIR/artisan
  
  # Create a helper script for Composer
  cat > $SITE_DIR/composer << EOF
#!/bin/bash
docker exec -it ${SITE_NAME}-app composer "\$@"
EOF
  chmod +x $SITE_DIR/composer
  
  # Create a helper script for npm/yarn
  cat > $SITE_DIR/npm << EOF
#!/bin/bash
docker exec -it ${SITE_NAME}-app npm "\$@"
EOF
  chmod +x $SITE_DIR/npm
  
  # Create backup directory
  mkdir -p ~/LaraHarbor/backups/${SITE_NAME}
  
  # Start containers
  docker compose up -d
  
  echo "Starting ${SITE_NAME} site..."
  echo "This may take a moment while containers initialize..."
  
  # Wait for services to be ready
  for i in {1..30}; do
    echo -n "."
    
    # Check if site is up
    RESPONSE=$(curl -s -k -o /dev/null -w "%{http_code}" https://${SITE_DOMAIN}/)
    if [ "$RESPONSE" == "200" ]; then
      echo " Ready!"
      break
    fi
    
    if [ $i -eq 30 ]; then
      echo ""
      echo "⚠️ Site initialization is taking longer than expected. The site should become available shortly."
      echo "You can check the logs with 'cd ${SITE_DIR} && docker compose logs -f'"
    fi
    
    sleep 2
  done
  
  echo "✅ LaraHarbor site created successfully!"
  echo "🌐 Site URL: https://${SITE_DOMAIN}"
  echo "🛠 Database Admin: https://admin.${SITE_DOMAIN}"
  echo "📧 Mail catcher UI: https://mail.local"
  echo "📁 Site directory: ${SITE_DIR}"
  echo ""
  echo "📂 Laravel files are directly accessible at: ${SITE_DIR}/src"
  echo "💾 Daily backups will be stored in ~/LaraHarbor/backups/${SITE_NAME}/"
  echo ""
  echo "Helper scripts created:"
  echo "  - ./artisan  - Run Laravel Artisan commands"
  echo "  - ./composer - Run Composer commands"
  echo "  - ./npm      - Run npm commands"
  echo ""
  echo "⚠️ Since this uses self-signed certificates, you'll need to accept the security warning in your browser."
  echo "📧 All emails sent from Laravel will be captured by MailHog and available at https://mail.local"
  
  # Make sure everything is initialized properly before returning
  cd $SITE_DIR/src
  
  # Install predis if Redis is enabled
  if [[ "$REDIS_CHOICE" == "y" ]]; then
    docker exec ${SITE_NAME}-app composer require predis/predis --no-interaction
  fi
  
  # Generate application key if not already set
  APP_KEY=$(docker exec ${SITE_NAME}-app grep "APP_KEY=" .env | cut -d '=' -f2)
  if [[ -z "$APP_KEY" || "$APP_KEY" == "" ]]; then
    docker exec ${SITE_NAME}-app php artisan key:generate
  fi
  
  echo ""
  echo "Your site should now be ready to serve at https://${SITE_DOMAIN}"
}

# ----- Manual Database Backup -----
backup_site() {
  read -p "Enter site name to backup: " SITE_NAME
  SITE_DIR=~/LaraHarbor/${SITE_NAME}
  
  if [ ! -d "$SITE_DIR" ]; then
    echo "❌ Site not found: $SITE_NAME"
    return
  fi
  
  # Create backup directory if it doesn't exist
  BACKUP_DIR=~/LaraHarbor/backups/${SITE_NAME}
  mkdir -p $BACKUP_DIR
  
  # Get database connection info from .env file
  if [ -f "$SITE_DIR/src/.env" ]; then
    DB_USERNAME=$(grep DB_USERNAME "$SITE_DIR/src/.env" | cut -d '=' -f2)
    DB_PASSWORD=$(grep DB_PASSWORD "$SITE_DIR/src/.env" | cut -d '=' -f2)
    DB_DATABASE=$(grep DB_DATABASE "$SITE_DIR/src/.env" | cut -d '=' -f2)
    DB_CONNECTION=$(grep DB_CONNECTION "$SITE_DIR/src/.env" | cut -d '=' -f2)
  else
    DB_USERNAME="laravel"
    DB_PASSWORD="laravel"
    DB_DATABASE="laravel"
    DB_CONNECTION="mysql"
  fi
  
  # Create timestamp for backup file
  TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
  BACKUP_FILE="${BACKUP_DIR}/${TIMESTAMP}-${SITE_NAME}-backup.sql"
  
  echo "Backing up database for site: $SITE_NAME"
  
  # Check if site is running
  if ! docker ps | grep -q "${SITE_NAME}-db"; then
    echo "⚠️ Site is not running. Starting containers..."
    cd "$SITE_DIR"
    docker compose up -d
    sleep 5  # Give containers time to start
  fi
  
  # Perform the database backup
  if [[ "$DB_CONNECTION" == "pgsql" ]]; then
    # PostgreSQL backup
    if docker exec "${SITE_NAME}-db" pg_dump -U "${DB_USERNAME}" "${DB_DATABASE}" > "$BACKUP_FILE"; then
      echo "✅ Database backup created successfully!"
      echo "📁 Backup location: $BACKUP_FILE"
      echo "📊 Backup size: $(du -h "$BACKUP_FILE" | cut -f1)"
    else
      echo "❌ Backup failed. Please check if the site is running."
    fi
  else
    # MySQL backup (default)
    if docker exec "${SITE_NAME}-db" mysqldump -u "${DB_USERNAME}" -p"${DB_PASSWORD}" "${DB_DATABASE}" > "$BACKUP_FILE"; then
      echo "✅ Database backup created successfully!"
      echo "📁 Backup location: $BACKUP_FILE"
      echo "📊 Backup size: $(du -h "$BACKUP_FILE" | cut -f1)"
    else
      echo "❌ Backup failed. Please check if the site is running."
    fi
  fi
}

# ----- List All Sites -----
list_sites() {
  echo "LaraHarbor Sites:"
  echo "================"
  
  local site_count=0
  
  for site in ~/LaraHarbor/*/docker-compose.yml; do
    if [ "$site" != "~/LaraHarbor/*/docker-compose.yml" ] && \
       [ "$site" != "~/LaraHarbor/proxy/docker-compose.yml" ] && \
       [ "$site" != "~/LaraHarbor/mailhog/docker-compose.yml" ] && \
       [ "$site" != "~/LaraHarbor/backups/docker-compose.yml" ]; then
      site_dir=$(dirname "$site")
      site_name=$(basename "$site_dir")
      site_domain="${site_name}.local"
      
      # Check if running
      if docker ps --format '{{.Names}}' | grep -q "${site_name}-app"; then
        status="✅ Running"
      else
        status="❌ Stopped"
      fi

      # Check if backups exist
      backup_count=$(find ~/LaraHarbor/backups/${site_name} -name "*.sql" 2>/dev/null | wc -l)
      
      # Print site information
      echo "- ${site_name}"
      echo "  URL: https://${site_domain}"
      echo "  Status: ${status}"
      echo "  Admin: https://admin.${site_domain}"
      echo "  Backups: ${backup_count} available"
      echo ""
      
      ((site_count++))
    fi
  done
  
  if [ $site_count -eq 0 ]; then
    echo "No sites found. Create a new site with: harbor create"
  else
    echo "${site_count} site(s) found."
  fi
}

# ----- Start All Sites -----
start_all_sites() {
  echo "Starting all LaraHarbor sites..."
  
  # First, make sure the proxy is running
  cd ~/LaraHarbor/proxy
  docker compose up -d
  
  # Then start mailhog
  cd ~/LaraHarbor/mailhog
  docker compose up -d
  
  # Then start all sites
  for site in ~/LaraHarbor/*/docker-compose.yml; do
    if [ "$site" != "~/LaraHarbor/*/docker-compose.yml" ] && \
       [ "$site" != "~/LaraHarbor/proxy/docker-compose.yml" ] && \
       [ "$site" != "~/LaraHarbor/mailhog/docker-compose.yml" ] && \
       [ "$site" != "~/LaraHarbor/backups/docker-compose.yml" ]; then
      site_dir=$(dirname "$site")
      site_name=$(basename "$site_dir")
      
      echo "Starting ${site_name}..."
      cd "$site_dir"
      docker compose up -d
    fi
  done
  
  echo "✅ All sites started!"
}

# ----- Stop All Sites -----
stop_all_sites() {
  echo "Stopping all LaraHarbor sites..."
  
  # Stop all sites first
  for site in ~/LaraHarbor/*/docker-compose.yml; do
    if [ "$site" != "~/LaraHarbor/*/docker-compose.yml" ] && \
       [ "$site" != "~/LaraHarbor/proxy/docker-compose.yml" ] && \
       [ "$site" != "~/LaraHarbor/mailhog/docker-compose.yml" ] && \
       [ "$site" != "~/LaraHarbor/backups/docker-compose.yml" ]; then
      site_dir=$(dirname "$site")
      site_name=$(basename "$site_dir")
      
      echo "Stopping ${site_name}..."
      cd "$site_dir"
      docker compose down
    fi
  done
  
  # Then stop mailhog
  cd ~/LaraHarbor/mailhog
  docker compose down
  
  # Then stop proxy
  cd ~/LaraHarbor/proxy
  docker compose down
  
  echo "✅ All sites stopped!"
}

# ----- Delete Site -----
delete_site() {
  read -p "Enter site name to delete: " SITE_NAME
  SITE_DIR=~/LaraHarbor/${SITE_NAME}
  
  if [ ! -d "$SITE_DIR" ]; then
    echo "❌ Site not found: $SITE_NAME"
    return
  fi
  
  # Confirm deletion
  read -p "⚠️ Are you sure you want to delete ${SITE_NAME}? This action cannot be undone! (y/n): " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Deletion cancelled."
    return
  fi
  
  # Stop containers if running
  cd "$SITE_DIR"
  docker compose down
  
  # Create a final backup
  echo "Creating final backup before deletion..."
  backup_site
  
  # Remove the site directory
  cd ~/LaraHarbor
  rm -rf "$SITE_DIR"
  
  # Remove from hosts file
  SITE_DOMAIN="${SITE_NAME}.local"
  sudo sed -i '' "/\s${SITE_DOMAIN}/d" /etc/hosts
  
  echo "✅ Site ${SITE_NAME} has been deleted."
  echo "💾 A final backup was saved to ~/LaraHarbor/backups/${SITE_NAME}/"
}

# ----- Main Script -----
# Parse command-line arguments
case "$1" in
  setup)
    setup_system
    ;;
  create)
    create_site
    ;;
  backup)
    backup_site
    ;;
  list)
    list_sites
    ;;
  start-all)
    start_all_sites
    ;;
  stop-all)
    stop_all_sites
    ;;
  delete)
    delete_site
    ;;
  *)
    echo "LaraHarbor: Laravel Multi-Site Management"
    echo "usage: $0 <command>"
    echo ""
    echo "Available commands:"
    echo "  setup        Initial setup of LaraHarbor system (run once)"
    echo "  create       Create a new Laravel site"
    echo "  backup       Manually backup a site's database"
    echo "  list         List all sites and their status"
    echo "  start-all    Start all sites"
    echo "  stop-all     Stop all sites"
    echo "  delete       Delete a site"
    echo ""
    exit 1
    ;;
esac

exit 0
