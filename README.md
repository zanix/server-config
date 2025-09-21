# Server Configuration Repository

This repository contains configuration files and scripts for managing and securing a Linux server. It includes settings for system security, cron jobs, backups, web server (nginx), SSH, MySQL, PHP, and more.

> [!TIP]
> There are probably better ways to handle this configuration for new servers like one of the various automation tools such as ansible or puppet, but I haven't figured those out yet.

## Directory Structure

- `etc/` - Contains configuration files for system services:
  - `backup/` — Backup scripts and configuration for databases, websites, and system files.
  - `cron.d/` — Custom cron job definitions.
  - `fail2ban/` — Fail2ban jail and filter configurations.
  - `mysql/` — MariaDB/MySQL configuration files.
  - `nginx/` — Nginx main config, SSL params, and site definitions.
  - `ssh/` — SSH daemon configuration snippets.
  - `sysctl.d/` — Kernel parameter tuning for security and networking.
- `scripts/` - Utility scripts for system management (e.g., PHP configuration).
- `usr/local/bin/` - Custom scripts for server management, such as:
  - `drupal-perms.sh` — Fixes permissions for Drupal installations.
  - `nginx_modsite` — Enables/disables nginx sites.
  - `showcron.sh` — Lists and analyzes cron jobs.
  - `wgetarx.sh` — Downloads and extracts tarballs in one step.

## Setup Instructions

### 0. Checkout this Repository

```sh
git clone https://github.com/zanix/server-config.git
```

### 1. Replace Placeholder Values

Some configuration files use placeholders such as `full_name` and `email@domain.tld`.
Replace these with your actual values using `sed`:

```sh
find etc/ -type f -exec sed -i 's/full_name/Your Name/g' {} +
find etc/ -type f -exec sed -i 's/email@domain.tld/your@email.com/g' {} +
```

### 2. Set Script Permissions

Ensure all scripts in `usr/local/bin/`, `scripts/`, and `etc/backup` are executable:

```sh
chmod +x usr/local/bin/*
chmod +x scripts/*
chmod +x etc/backup/*
```

Ensure restic env file is read only for root.

```sh
chmod 600 etc/backup/restic.env
```

### 3. Review and Edit

- Review all configuration files for environment-specific settings.
- Edit backup scripts in `etc/backup/` as needed for your backup destinations and retention policies.
- Adjust PHP versions in `scripts/php-config` if necessary.

### 4. Deploy Configuration Files

> [!IMPORTANT]
> You should review each folder and only copy over the configuration that is needed!
> For example, `etc/mysql/mariadb.conf.d/maria*.conf` contains multiple configurations for varing levels of RAM usage.
> Pick ONLY 1 configuration and copy to `/etc/mysql/mariadb.conf.d`.

Copy the configuration files to their respective locations on your server.

Be sure to evaluate all scripts and configurations before copying!

### 5. Reload/Restart Services

After copying configuration files, reload or restart affected services, e.g.:

```sh
sudo systemctl reload nginx
sudo systemctl restart fail2ban
sudo systemctl restart mysql
sudo systemctl restart php8.4-fpm
```

## Notes

- The `showcron.sh` script provides a comprehensive overview of all cron jobs and their status.
- The `nginx_modsite` script helps enable or disable nginx site configurations.
- The repository is intended for advanced users familiar with Linux server administration.

## License

See individual scripts for license information. Most scripts are provided "as is"
