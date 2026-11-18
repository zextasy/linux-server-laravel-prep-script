# linux-server-laravel-prep-script

One script that prepares a fresh Linux server to host a Laravel application.

## What it sets up

| Component | Details |
|-----------|---------|
| PHP | 8.4 by default (`--php-version`), FPM + the extensions Laravel needs (`pgsql`, `mbstring`, `xml`, `curl`, `zip`, `bcmath`, `intl`, `gd`, `redis`, `opcache`) and sane `php.ini` overrides |
| Web server | Nginx with a Laravel-ready vhost at `/etc/nginx/conf.d/<app>.conf` |
| Database | PostgreSQL (distro packages), plus a role and database for the app with a random password |
| Cache/queues | Redis (Valkey on EL10) |
| Tooling | Composer (installer checksum verified), Node.js (tarball checksum verified), git, unzip |
| Processes | Supervisor queue-worker definition (not started), cron entry for `schedule:run` |
| Hardening | Dedicated deploy user, firewall (ufw / firewalld) allowing SSH, 80 and 443, SELinux booleans and labels on RHEL-family |

## Supported distributions

systemd-based only.

| Family | Distros | PHP source |
|--------|---------|------------|
| Debian | Ubuntu, Debian | [ondrej/php PPA](https://launchpad.net/~ondrej/+archive/ubuntu/php) / [packages.sury.org](https://packages.sury.org) |
| RHEL | RHEL 8+, CentOS Stream, Rocky, AlmaLinux, Oracle Linux | [Remi](https://rpms.remirepo.net) (`phpXY-php-*` packages) |
| Fedora | Fedora | Remi |

Not supported: Alpine, Arch, openSUSE, Amazon Linux, and Debian/Ubuntu
derivatives such as Mint. Containers without systemd also won't work.

> **Testing status:** run end to end (fresh install and a second run) in systemd
> containers on **Ubuntu 24.04**, **Debian 12** and **Rocky Linux 9**, each with a
> PHP page served through Nginx + PHP-FPM and a PostgreSQL login using the
> generated credentials. Not yet run on: Fedora, RHEL itself, AlmaLinux, Oracle
> Linux, CentOS Stream, older/newer releases, or with the firewall step enabled
> (`--skip-firewall` was used) or with SELinux enforcing. Treat those as untested
> and try on a disposable VM first.

## Usage

```bash
git clone https://github.com/zextasy/linux-server-laravel-prep-script.git
cd linux-server-laravel-prep-script
sudo ./laravel-prep.sh --app-name myapp --domain example.com
```

Read the script before running it. It installs packages, edits the firewall and
runs as root.

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--php-version X.Y` | `8.4` | PHP version |
| `--node-version N` | `22` | Node.js major version |
| `--app-name NAME` | `laravel` | Used for `/var/www/NAME`, the vhost, and DB defaults (`[a-z][a-z0-9_]*`) |
| `--domain DOMAIN` | catch-all | Nginx `server_name` |
| `--deploy-user USER` | `deploy` | Unix user that owns the code |
| `--db-name NAME` | app name | PostgreSQL database |
| `--db-user NAME` | app name | PostgreSQL role |
| `--no-node` | | Skip Node.js |
| `--skip-firewall` | | Leave the firewall alone |

The script is safe to re-run: existing roles, databases, vhosts and users are
left as they are (an existing vhost is never overwritten).

## After the script runs

1. **Database credentials** are in `/root/.laravel-prep/<app>.env`. Copy the
   `DB_*` lines into your app's `.env`.
2. **Deploy your code** to `/var/www/<app>` as the deploy user:
   ```bash
   sudo -u deploy git clone <repo> /var/www/myapp
   cd /var/www/myapp
   sudo -u deploy composer install --no-dev --optimize-autoloader
   sudo -u deploy npm ci && sudo -u deploy npm run build
   sudo -u deploy php artisan key:generate && sudo -u deploy php artisan migrate --force
   ```
3. **Make `storage` and `bootstrap/cache` writable by PHP-FPM.** The group is
   `www-data` on Debian/Ubuntu and `nginx` on RHEL-family:
   ```bash
   sudo chgrp -R www-data /var/www/myapp/storage /var/www/myapp/bootstrap/cache
   sudo chmod -R ug+rwX   /var/www/myapp/storage /var/www/myapp/bootstrap/cache
   ```
   On SELinux systems the script already labels these paths; run
   `sudo restorecon -R /var/www/myapp` after deploying.
4. **Start the queue worker** (if you use queues):
   ```bash
   sudo supervisorctl reread && sudo supervisorctl update
   sudo supervisorctl start myapp-worker
   ```
   The scheduler cron entry (`/etc/cron.d/laravel-<app>`) starts working as soon
   as `artisan` exists.
5. **Enable HTTPS** with [certbot](https://certbot.eff.org/) once the domain
   points at the server.

## Notes and caveats

- **Firewall:** the script detects your SSH port via `sshd -T` (falling back to
  22) and allows it before enabling the firewall. Use `--skip-firewall` if you
  manage firewalling elsewhere.
- **PostgreSQL version** is whatever the distro ships (EL8 is pinned to the
  16 stream). Postgres listens on localhost only.
- **RHEL-family PHP** uses Remi's parallel-install packages. The CLI is
  available as `php` (symlinked to `php84` or similar), FPM listens on
  `127.0.0.1:9000`, and its config lives under `/etc/opt/remi/phpXY/`.
- **RHEL proper** needs an active subscription for the CodeReady Builder repo;
  the script warns and continues if that can't be enabled.

## License

No license has been chosen yet.
