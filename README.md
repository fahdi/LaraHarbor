# LaraHarbor

A Docker-based Laravel local development environment manager that allows you to create, manage, and run multiple isolated Laravel applications on your local machine.

![LaraHarbor Logo](https://via.placeholder.com/800x200?text=LaraHarbor)

## Overview

LaraHarbor provides a simple and efficient way to set up complete Laravel development environments with a single command. Each environment is fully isolated with its own database, web server, and optional services like Redis, all accessible via a convenient `.local` domain.

### Key Features

- **One-command Setup**: Create complete Laravel environments by just entering a site name
- **Isolated Environments**: Each project runs in its own containers with dedicated resources
- **SSL Support**: Automatic SSL certificates for local development with `.local` domains
- **Database Options**: Choose between MySQL and PostgreSQL for each project
- **Mail Testing**: Integrated MailHog to capture and preview emails during development
- **Redis Support**: Optional Redis for caching and queue management
- **Easy Management**: Simple commands to create, start, stop, and delete environments
- **Simple Backups**: Automated and on-demand database backups
- **Developer Tools**: Wrapper scripts for Artisan, Composer, and npm
- **Clean Organization**: All sites stored in a consistent directory structure

## Installation

### Prerequisites

- Docker and Docker Compose
- Git
- Linux/macOS (Windows users should use WSL2)

### Quick Install

1. Clone the repository:

```bash
git clone https://github.com/yourusername/laraharbor.git
cd laraharbor
```

2. Make the script executable:

```bash
chmod +x laraharbor.sh
```

3. Run the setup:

```bash
./laraharbor.sh
```

4. Select option 1 to perform the first-time setup

## Usage

### Creating a New Laravel Site

```bash
./laraharbor.sh
```

Select option 2, then follow the prompts to:
- Enter a site name (e.g., "myproject")
- Choose a database type (MySQL or PostgreSQL)
- Decide whether to include Redis
- Select whether to create a new Laravel project or import an existing one

Your new site will be available at:
- Website: `https://myproject.local`
- Database Admin: `https://admin.myproject.local`
- Mail Catcher: `https://mail.local`

### Managing Your Sites

Run `./laraharbor.sh` and choose from the menu options:

- **List all sites**: View all your LaraHarbor sites and their status
- **Start a site**: Bring up a specific site's containers
- **Stop a site**: Shut down a specific site's containers
- **Delete a site**: Remove a site and its containers
- **Backup a site**: Create a database backup for a specific site
- **Start/Stop mail system**: Control the mail testing environment
- **Start/Stop backup system**: Control automatic backups

### Accessing Your Laravel Project

LaraHarbor creates helpful shortcuts in each project directory:

```bash
cd ~/LaraHarbor/myproject/

# Run artisan commands
./artisan migrate

# Run composer commands
./composer require guzzlehttp/guzzle

# Run npm commands
./npm install
./npm run dev
```

### Project Structure

Each project follows this structure:

```
~/LaraHarbor/
  ├── myproject/
  │   ├── docker/           # Docker configuration files
  │   ├── src/              # Laravel application files
  │   ├── database/         # Database data files
  │   ├── logs/             # Log files
  │   ├── docker-compose.yml
  │   ├── .env
  │   ├── README.md         # Project-specific documentation
  │   ├── artisan           # Artisan command helper
  │   ├── composer          # Composer command helper
  │   └── npm               # npm command helper
  ├── proxy/                # Nginx proxy service
  ├── mailhog/              # Mail testing service
  └── backups/              # Database backups
      └── myproject/        # Project-specific backups
```

## Customization

Each Laravel environment includes:

- PHP 8.2 with common extensions
- Nginx web server
- MySQL 8.0 or PostgreSQL 14
- Redis (optional)
- phpMyAdmin or Adminer for database management
- MailHog for mail testing

You can customize the PHP version, extensions, or add more services by modifying the Dockerfile and docker-compose.yml files in your project directory.

## Troubleshooting

### Certificate Warnings

Your browser will show warnings about self-signed certificates. This is normal for local development. You can:

- Click "Advanced" and proceed to the site
- Add a permanent exception for these domains

### Port Conflicts

If you have services already using ports 80 or 443, you'll need to stop them before running LaraHarbor.

### Permission Issues

If you encounter permission problems:

```bash
# Fix storage directory permissions
docker exec -it myproject-app chown -R www-data:www-data /var/www/html/storage
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is open-source software licensed under the MIT license.