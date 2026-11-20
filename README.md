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
| Tooling | Composer (installer checksum verified; an existing install is updated to the current stable release), Node.js (tarball checksum verified), git, unzip, cron, Supervisor |
| HTTPS | certbot with the Nginx plugin (Let's Encrypt) and its automatic-renewal timer (`--no-certbot` to skip) |
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
> | Distro | PostgreSQL | certbot | Notes |
> |--------|-----------|---------|-------|
> | Ubuntu 24.04 | 16 | 2.9 | |
> | Debian 12 | 15 | 2.1 | |
> | Rocky Linux 9 | 13 | 3.1 | |
> | AlmaLinux 8 | 16 | 1.22 | uses the `postgresql:16` module stream |
> | AlmaLinux 9 | 13 | 3.1 | |
> | Oracle Linux 9 | 13 | 3.1 | uses `oracle-epel-release`; x86_64 tested, aarch64 only dependency-resolved (see notes) |
> | CentOS Stream 9 | 13 | 3.1 | |
> | CentOS Stream 10 | 16 | 4.2 | Valkey instead of Redis |
> | Fedora 43 | 18 | 5.7 | dnf5; needs `python3-pyparsing` for certbot's nginx plugin (installed automatically) |
>
> **certbot / `--https`** was tested on every distro in the table with real certbot
> against a local ACME test CA ([Pebble](https://github.com/letsencrypt/pebble)):
> issuing and deploying a certificate, the HTTP-to-HTTPS redirect, serving over TLS,
> a re-run keeping the certificate, `certbot renew --dry-run`, a forced renewal that
> Nginx picks up, and `--remove` deleting the certificate. It has **not** been run
> against the real Let's Encrypt (which needs a public domain). `--clone`,
> `--install` and `--deploy-key` were tested (against a local SSH git server, with
> real Composer and npm runs) on Ubuntu 24.04, Debian 12, AlmaLinux 8 and 9, Oracle
> Linux 9, CentOS Stream 9 and 10, and Fedora 43: the deploy key and its permissions,
> an unauthorised key stopping safely, clone + install + permissions + serving, `.env`
> from `.env.example`, a plain `git pull` with the deploy key, re-running on an
> existing checkout, `--branch` with the interactive Enter-to-retry flow, refusals
> (HTTPS URL, non-empty target), and `--remove` deleting the key while keeping the
> code. Rocky Linux 9 was not run through this set.
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
| `--no-certbot` | | Skip certbot |
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
| `--clone URL` | | Clone a private repo over SSH with a per-app deploy key, then set it up (see below) |
| `--branch BRANCH` | | With `--clone`: branch or tag to check out |
| `--user USER` | the user who ran `sudo` | With `--clone`: Unix user that owns the code (created if missing) |
| `--https` | | Get a Let's Encrypt certificate for `--domain` and switch the site to HTTPS (see below) |
| `--email EMAIL` | | With `--https`: contact address for Let's Encrypt (required the first time on a server) |
| `--staging` | | With `--https`: use Let's Encrypt's staging CA (untrusted certificate, no rate limits) |
| `--install` | | Install dependencies as the code's owner: `composer install` and, if there is a `package.json`, `npm ci` + `npm run build` |
| `--deploy-key` | | Create an SSH deploy key for the app's owner and point the app's git repo at it (see below) |
| `--force` | | Continue even if there is no `artisan` file |
| `--remove` | | Undo the setup of this app (see below) |
| `--drop-db` | | With `--remove`: also delete the app's database and role |
| `--yes` | | Skip the `--drop-db` confirmation prompt |

`laravel-app` is safe to re-run: an existing role keeps its password and an
existing vhost is never overwritten (delete `/etc/nginx/conf.d/<app>.conf` and
re-run to regenerate it). If Nginx rejects a new vhost, it is removed again.

### Cloning a private repository and setting it up

Instead of cloning by hand, let `laravel-app` do both:

```bash
sudo laravel-app --clone git@github.com:acme/shop.git --domain shop.example.com --update-env
```

What happens:

1. The code goes to `/var/www/<repo>` (override with `--path`), owned by the user who
   ran `sudo` (override with `--user`).
2. An SSH deploy key is created for that user, and its **public key is printed**.
3. Add it as a **read-only deploy key** on the repo (GitHub: repo, Settings, Deploy keys;
   GitLab: repo, Settings, Repository, Deploy keys). In a terminal the script waits and
   retries when you press Enter. Without a terminal (scripts, CI) it stops and tells you
   to re-run the same command once the key is added; the key is kept.
4. It clones (`--branch` to pick a branch or tag), points the checkout at its key so a
   later `git pull` works with plain `git`, and then runs the normal app setup. With
   `--update-env`, a fresh clone's `.env` is created from `.env.example` first.

Run it once per repository; each repo gets its own key, because GitHub requires a
unique deploy key per repository:

```bash
sudo laravel-app --clone git@github.com:acme/shop.git --domain shop.example.com
sudo laravel-app --clone git@github.com:acme/blog.git --domain blog.example.com --branch release
```

Only SSH URLs are accepted (`git@host:owner/repo.git` or `ssh://git@host/...`); a
private repo over HTTPS would need a token, which these scripts don't store. Re-running
with the same URL reuses the existing checkout and key. The clone doesn't run
`composer install` or build assets; do that as the code's owner afterwards (see below).

### HTTPS with Let's Encrypt (`--https`)

```bash
sudo laravel-app --domain shop.example.com --https --email you@example.com
# or together with the clone:
sudo laravel-app --clone git@github.com:acme/shop.git --domain shop.example.com --https --email you@example.com --install
```

This runs certbot's Nginx plugin for the app's domain: it gets a free certificate,
adds the HTTPS listener to the app's vhost and redirects HTTP to HTTPS.

Before you run it:

- The domain's DNS record must **already point at this server**, and ports 80 and 443
  must be reachable from the internet (`laravel-prep.sh` opens both in the firewall).
  Let's Encrypt checks by fetching a file over port 80.
- Pass `--email` the first time on a server (Let's Encrypt sends expiry notices there);
  later apps reuse the same account.
- You need a real domain name. The catch-all vhost and bare IP addresses can't get a
  certificate. Try `--staging` first if you are experimenting, to avoid Let's Encrypt's
  rate limits (it issues untrusted test certificates).

Renewal is automatic: `laravel-prep.sh` enables certbot's systemd timer
(`certbot.timer` on Debian/Ubuntu, `certbot-renew.timer` on RHEL-family/Fedora), and
Nginx is reloaded when a certificate renews. Check it any time with
`sudo certbot renew --dry-run`.

If certbot fails (DNS not ready, port blocked, rate limit), the rest of the setup still
completes, the site keeps working over HTTP, and the script exits 1 with the reason
printed; fix the cause and re-run the same command. Re-running when a valid certificate
exists keeps it. `laravel-app --remove` deletes the app's certificate (it does not
revoke it).

### Installing dependencies (`--install`)

Add `--install` to install an app's dependencies in the same step, for example after a clone:

```bash
sudo laravel-app --clone git@github.com:acme/shop.git --domain shop.example.com --install --update-env
# or, in an app that is already there:
cd /var/www/shop && sudo laravel-app --install
```

It runs **as the user who owns the code**, never as root, before the permissions step so
everything it creates gets the right group:

- If there is a `composer.json`: `composer install --no-dev --optimize-autoloader`
  (production mode: dev dependencies are skipped).
- If there is a `package.json`: `npm ci` (or `npm install` when there is no
  `package-lock.json`), then `npm run build` if `package.json` has a `build` script.
  Dev dependencies are installed so the build tools (Vite, etc.) are available.

If a step fails, the rest of the setup still completes and the script finishes with a
warning and exit status 1. If npm isn't installed (for example you used `--no-node`),
the npm part is skipped with a warning. `--install` doesn't run `php artisan` commands:
after it you still need `key:generate`, `migrate --force`, and so on.

### Pulling a private repository you already cloned (deploy key)

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
2. **Install and migrate** as the user who owns the code (skip the first lines if you
   used `--install`):
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
4. **Enable HTTPS** once the domain points at the server: re-run
   `sudo laravel-app --https --email you@example.com` in the app directory (see above).

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
- **`sudo` and `/usr/local` (RHEL-family):** `sudo` there uses a `secure_path` that
  leaves out `/usr/local/bin` and `/usr/local/sbin`, where `composer`, `node` and
  `laravel-app` live. `laravel-prep.sh` adds a validated drop-in,
  `/etc/sudoers.d/laravel-prep-path`, so `sudo laravel-app` and
  `sudo -u deploy composer ...` work. Both scripts also add those directories to
  their own `PATH`. Debian/Ubuntu need nothing.
- **RHEL proper** needs an active subscription for the CodeReady Builder repo;
  the script warns and continues if that can't be enabled.
- **Nginx reloads are asynchronous:** a new vhost can take a second or two to
  start answering after `laravel-app` returns.

## License

No license has been chosen yet.
