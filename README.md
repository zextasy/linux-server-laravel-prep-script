# linux-server-laravel-prep-script

Two scripts for hosting Laravel apps on a Linux server:

| Script | Run | Purpose |
|--------|-----|---------|
| `laravel-prep.sh` | **once per server** | Installs PHP, Nginx, PostgreSQL, Redis, Composer, Node.js, Supervisor, cron; configures the firewall |
| `laravel-app.sh` | **once per app**, from the app's directory | Gives that app its own Nginx vhost, PostgreSQL role + database, scheduler, queue worker and permissions |

`laravel-prep.sh` records what it detected in `/etc/laravel-prep/server.conf`
and installs `laravel-app.sh` as `/usr/local/sbin/laravel-app`, so the per-app
step needs no OS detection and works the same on every supported distro. You
can host as many apps as you like on one server.

## What gets set up

**Server (`laravel-prep.sh`)**

| Component | Details |
|-----------|---------|
| PHP | 8.4 by default (`--php-version`), FPM + the extensions Laravel needs (`pgsql`, `mbstring`, `xml`, `curl`, `zip`, `bcmath`, `intl`, `gd`, `redis`, `opcache`) and sane `php.ini` overrides |
| Web server | Nginx (no sites yet) |
| Database | PostgreSQL (distro packages), listening on localhost |
| Cache/queues | Redis (Valkey on EL10) |
| Tooling | Composer (installer checksum verified), Node.js (tarball checksum verified), git, unzip, cron, Supervisor |
| Hardening | Firewall (ufw / firewalld) allowing SSH, 80 and 443; SELinux booleans on RHEL-family |

**Per app (`laravel-app.sh`)**

| Component | Details |
|-----------|---------|
| Nginx vhost | `/etc/nginx/conf.d/<app>.conf`, root `<app dir>/public` |
| Database | Role + database named after the app, random password saved to `/root/.laravel-prep/<app>.env` |
| Scheduler | `/etc/cron.d/laravel-<app>` running `schedule:run` every minute |
| Queue worker | Supervisor program `<app>-worker` (defined, not started unless `--start-worker`) |
| Permissions | Group set to the web server's group, world-write removed, `storage/` and `bootstrap/cache` group-writable, `.env` mode 640, SELinux labels on RHEL-family |

## Supported distributions

systemd-based only.

| Family | Distros | PHP source |
|--------|---------|------------|
| Debian | Ubuntu, Debian | [ondrej/php PPA](https://launchpad.net/~ondrej/+archive/ubuntu/php) / [packages.sury.org](https://packages.sury.org) |
| RHEL | RHEL 8+, CentOS Stream, Rocky, AlmaLinux, Oracle Linux | [Remi](https://rpms.remirepo.net) (`phpXY-php-*` packages) |
| Fedora | Fedora | Remi |

Not supported: Alpine, Arch, openSUSE, Amazon Linux, and Debian/Ubuntu
derivatives such as Mint. Containers without systemd also won't work.

> **Testing status:** the server script was run end to end (fresh install, then a
> second run) in systemd containers on each distro below, each serving a PHP page
> through Nginx + PHP-FPM. The split into two scripts was then re-verified with
> two apps on a single server on **Ubuntu 24.04** and **Rocky Linux 9** (each app
> served its own page and logged in to its own database). `--remove` (with and
> without `--drop-db`) was tested on Ubuntu 24.04 only; the other distros were
> tested with the earlier single-script version, whose server part is unchanged
> apart from the app/database steps moving to `laravel-app`.
>
> | Distro | PostgreSQL | Notes |
> |--------|-----------|-------|
> | Ubuntu 24.04 | 16 | |
> | Debian 12 | 15 | |
> | Rocky Linux 9 | 13 | |
> | AlmaLinux 8 | 16 | uses the `postgresql:16` module stream |
> | AlmaLinux 9 | 13 | |
> | Oracle Linux 9 | 13 | uses `oracle-epel-release`; x86_64 tested, aarch64 only dependency-resolved (see notes) |
> | CentOS Stream 9 | 13 | |
> | CentOS Stream 10 | 16 | Valkey instead of Redis |
> | Fedora 43 | 18 | dnf5 |
>
> **Not tested:** RHEL itself (needs a subscription; Rocky/Alma/Oracle are
> rebuilds of it), Fedora 44+, other Ubuntu/Debian releases, the **firewall
> step** (`--skip-firewall` was used), and **SELinux in enforcing mode**
> (containers can't exercise either). Try those on a disposable VM first.

## Usage

### 1. Prepare the server (once)

```bash
git clone https://github.com/zextasy/linux-server-laravel-prep-script.git
cd linux-server-laravel-prep-script
sudo ./laravel-prep.sh
```

| Option | Default | Description |
|--------|---------|-------------|
| `--php-version X.Y` | `8.4` | PHP version |
| `--node-version N` | `22` | Node.js major version |
| `--no-node` | | Skip Node.js |
| `--skip-firewall` | | Leave the firewall alone |

Read the scripts before running them: they install packages, edit the firewall
and run as root. Re-running `laravel-prep.sh` is safe, and also refreshes the
installed `laravel-app`.

### 2. Set up each app (once per app)

Put the app's code on the server (anywhere with a plain path, e.g.
`/var/www/myapp`), then from **inside the app directory**:

```bash
cd /var/www/myapp
sudo laravel-app --domain myapp.example.com --update-env
```

Run it again in another directory for the next app:

```bash
cd /var/www/shop && sudo laravel-app --domain shop.example.com --update-env
```

| Option | Default | Description |
|--------|---------|-------------|
| `--domain DOMAIN` | catch-all | Nginx `server_name`. Only one app can use the catch-all; give the others a domain |
| `--name NAME` | from the directory name | Used for the vhost, cron, worker and DB defaults (`Blog-Site` becomes `blog_site`) |
| `--path DIR` | current directory | Set up an app without `cd`-ing into it |
| `--db-name` / `--db-user` | app name | PostgreSQL database / role |
| `--update-env` | | Write the `DB_*` settings into the app's `.env` (only when the role is newly created) |
| `--no-db` | | Skip the database (e.g. you use an external one) |
| `--no-scheduler` | | Skip the cron entry |
| `--no-worker` | | Skip the queue-worker definition |
| `--start-worker` | | Start the queue worker now |
| `--deploy-key` | | Create an SSH deploy key for the app's owner and point the app's git repo at it (see below) |
| `--force` | | Continue even if there is no `artisan` file |
| `--remove` | | Undo the setup of this app (see below) |
| `--drop-db` | | With `--remove`: also delete the app's database and role |
| `--yes` | | Skip the `--drop-db` confirmation prompt |

`laravel-app` is safe to re-run: an existing role keeps its password and an
existing vhost is never overwritten (delete `/etc/nginx/conf.d/<app>.conf` and
re-run to regenerate it). If Nginx rejects a new vhost, it is removed again.

### Pulling a private repository (deploy key)

```bash
cd /var/www/shop && sudo laravel-app --deploy-key
```

This creates an ed25519 key at `~/.ssh/laravel_<app>_deploy` for the user who
owns the app's files, prints the public key, and (if the directory is a git
checkout) sets `core.sshCommand` in that repo so `git pull` uses the key and no
other. Add the printed public key as a **read-only deploy key** on GitHub or
GitLab (repo settings, Deploy keys). GitHub requires a different key per
repository, which is why the key is per app. Re-running keeps the same key.

The key has no passphrase, so deploys can pull unattended; protect the server
accordingly. If the directory isn't a git checkout yet, the script prints a
`git clone` command that uses the key. `laravel-app --remove` deletes the key
(revoke it on your git host too).

### 3. Remove an app

```bash
cd /var/www/shop && sudo laravel-app --remove
```

This removes the app's Nginx vhost, cron entry, deploy key and Supervisor queue
worker (the worker is stopped first), then reloads Nginx and Supervisor. Other apps are
untouched. It **keeps** the app's files, its PostgreSQL database and role, and
`/root/.laravel-prep/<app>.env`, so removing is reversible: run `laravel-app`
again to put it back.

To delete the database too, add `--drop-db`. You are asked to type the database
name to confirm (nothing is changed if it doesn't match), or pass `--yes` for
scripts. The names used come from the saved credentials file, so a custom
`--db-name`/`--db-user` is found automatically.

If the app's directory is already gone, name it instead:

```bash
sudo laravel-app --remove --name shop --drop-db --yes
```

What `--remove` does not do: delete the app's code, revert the group and
permission changes, or delete `/var/log/<app>-worker.log`. Once an app is
removed, requests for its old hostname fall through to Nginx's default vhost
(the first one in `/etc/nginx/conf.d/`).

## After `laravel-app` runs

1. **Database credentials** are in `/root/.laravel-prep/<app>.env` (or already
   in `.env` if you used `--update-env`).
2. **Install and migrate** as the user who owns the code:
   ```bash
   composer install --no-dev --optimize-autoloader
   npm ci && npm run build
   php artisan key:generate && php artisan migrate --force
   ```
3. **Start the queue worker** (if you use queues), unless you passed `--start-worker`:
   ```bash
   sudo supervisorctl reread && sudo supervisorctl update
   sudo supervisorctl start <app>-worker
   ```
4. **Enable HTTPS** with [certbot](https://certbot.eff.org/) once the domain
   points at the server.

If you re-deploy files with a different group, run `sudo laravel-app` again to
restore the permissions.

## Notes and caveats

- **Where to keep apps:** the web server user must be able to walk down to the
  app. Directories under `/home/<user>` are usually mode 700, which blocks
  Nginx; `laravel-app` warns when it detects this. `/var/www/<app>` is the
  simplest choice. Paths may only contain letters, digits and `. _ / -`.
- **Permissions model:** the app keeps its owner (your deploy user); only the
  group changes to the web group (`www-data` on Debian/Ubuntu, `nginx` on
  RHEL-family). World-write is removed.
- **Firewall:** `laravel-prep.sh` detects your SSH port via `sshd -T` (falling
  back to 22) and allows it before enabling the firewall. Use `--skip-firewall`
  if you manage firewalling elsewhere.
- **PostgreSQL version** is whatever the distro ships (EL8 is pinned to the 16
  stream).
- **RHEL-family PHP** uses Remi's parallel-install packages. The CLI is
  available as `php` (symlinked to `php84` or similar), FPM listens on
  `127.0.0.1:9000`, and its config lives under `/etc/opt/remi/phpXY/`. All apps
  share one FPM pool.
- **Oracle Linux** uses `oracle-epel-release-elN` and enables its
  `olN_developer_EPEL` and `olN_codeready_builder` repos explicitly. PHP's `gd`
  extension needs libraries from them (`libavif`, `libraqm`, ...), so if PHP
  fails to install with a `libgd.so` dependency error, check `dnf repolist`
  shows both. On other RHEL-family distros the same symptom means EPEL or CRB
  is disabled.
- **RHEL proper** needs an active subscription for the CodeReady Builder repo;
  the script warns and continues if that can't be enabled.
- **Nginx reloads are asynchronous:** a new vhost can take a second or two to
  start answering after `laravel-app` returns.

## License

No license has been chosen yet.
