#!/usr/bin/env bash
#
# laravel-prep.sh - prepare a fresh Linux server to host a Laravel application.
#
# Installs and configures: PHP (+ FPM and the extensions Laravel needs), Nginx,
# PostgreSQL, Redis, Composer, Node.js, Supervisor (queue worker), a cron-based
# scheduler entry, a deploy user, and a firewall.
#
# Supported: Ubuntu, Debian, RHEL, CentOS Stream, Rocky Linux, AlmaLinux,
#            Oracle Linux, Fedora (all systemd based).
#
# Usage:  sudo ./laravel-prep.sh [options]      (see --help)

set -Eeuo pipefail
trap 'echo "ERROR: line $LINENO: command failed: $BASH_COMMAND" >&2' ERR

# --------------------------------------------------------------------------
# Defaults (override with flags or environment variables)
# --------------------------------------------------------------------------
PHP_VERSION="${PHP_VERSION:-8.4}"
NODE_MAJOR="${NODE_MAJOR:-22}"
APP_NAME="${APP_NAME:-laravel}"
DOMAIN="${DOMAIN:-_}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
INSTALL_NODE=1
SETUP_FIREWALL=1

usage() {
  cat <<EOF
Usage: sudo $0 [options]

  --php-version X.Y     PHP version to install            (default: $PHP_VERSION)
  --node-version N      Node.js major version             (default: $NODE_MAJOR)
  --app-name NAME       App name: dir, vhost, DB defaults (default: $APP_NAME)
  --domain DOMAIN       Nginx server_name                 (default: catch-all)
  --deploy-user USER    Unix user that owns the code      (default: $DEPLOY_USER)
  --db-name NAME        PostgreSQL database               (default: app name)
  --db-user NAME        PostgreSQL role                   (default: app name)
  --no-node             Skip Node.js
  --skip-firewall       Do not touch the firewall
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --php-version)   PHP_VERSION="${2:?}"; shift 2 ;;
    --node-version)  NODE_MAJOR="${2:?}"; shift 2 ;;
    --app-name)      APP_NAME="${2:?}"; shift 2 ;;
    --domain)        DOMAIN="${2:?}"; shift 2 ;;
    --deploy-user)   DEPLOY_USER="${2:?}"; shift 2 ;;
    --db-name)       DB_NAME="${2:?}"; shift 2 ;;
    --db-user)       DB_USER="${2:?}"; shift 2 ;;
    --no-node)       INSTALL_NODE=0; shift ;;
    --skip-firewall) SETUP_FIREWALL=0; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Every value below ends up in config files and SQL, so keep them strict.
[[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]     || die "Invalid --php-version: $PHP_VERSION"
[[ "$NODE_MAJOR" =~ ^[0-9]+$ ]]              || die "Invalid --node-version: $NODE_MAJOR"
[[ "$APP_NAME" =~ ^[a-z][a-z0-9_]*$ ]]       || die "--app-name must match ^[a-z][a-z0-9_]*$"
[[ "$DEPLOY_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]  || die "Invalid --deploy-user: $DEPLOY_USER"
[[ "$DOMAIN" =~ ^[A-Za-z0-9._-]+$ ]]         || die "Invalid --domain: $DOMAIN"
DB_NAME="${DB_NAME:-$APP_NAME}"
DB_USER="${DB_USER:-$APP_NAME}"
[[ "$DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]]       || die "--db-name must match ^[a-z_][a-z0-9_]*$"
[[ "$DB_USER" =~ ^[a-z_][a-z0-9_]*$ ]]       || die "--db-user must match ^[a-z_][a-z0-9_]*$"

PHP_NODOT="${PHP_VERSION/./}"
APP_DIR="/var/www/$APP_NAME"

[[ $EUID -eq 0 ]] || die "Run as root (e.g. sudo $0)"
[[ -d /run/systemd/system ]] || die "systemd is required (containers without systemd are not supported)"

# --------------------------------------------------------------------------
# OS detection
# --------------------------------------------------------------------------
[[ -r /etc/os-release ]] || die "/etc/os-release not found"
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"
OS_VER="${VERSION_ID:-0}"
OS_MAJOR="${OS_VER%%.*}"

case "$OS_ID" in
  ubuntu)                                     FAMILY=ubuntu ;;
  debian)                                     FAMILY=debian ;;
  rhel|centos|rocky|almalinux|ol)             FAMILY=rhel ;;
  fedora)                                     FAMILY=fedora ;;
  *)
    if   [[ " $OS_LIKE " == *" rhel "* ]];   then FAMILY=rhel;  warn "Unrecognised RHEL-like distro '$OS_ID'; proceeding as RHEL"
    elif [[ " $OS_LIKE " == *" debian "* ]]; then die "Debian/Ubuntu derivatives ('$OS_ID') are not supported; use plain Ubuntu or Debian"
    else die "Unsupported distro: $OS_ID. Supported: Ubuntu, Debian, RHEL, CentOS Stream, Rocky, AlmaLinux, Oracle Linux, Fedora"
    fi ;;
esac

if [[ "$FAMILY" == "rhel" && "$OS_MAJOR" -lt 8 ]]; then
  die "RHEL-family version 8 or newer is required (found $OS_VER)"
fi

case "$FAMILY" in
  ubuntu|debian)
    PM=apt
    WEB_USER=www-data; WEB_GROUP=www-data
    PHP_BIN=/usr/bin/php
    FPM_SERVICE="php${PHP_VERSION}-fpm"
    FPM_PASS="unix:/run/php/php${PHP_VERSION}-fpm.sock"
    PHP_INI_DIRS=("/etc/php/${PHP_VERSION}/fpm/conf.d" "/etc/php/${PHP_VERSION}/cli/conf.d")
    PG_SERVICE=postgresql
    SUPERVISOR_SERVICE=supervisor
    SUPERVISOR_CONF="/etc/supervisor/conf.d/${APP_NAME}-worker.conf"
    CRON_SERVICE=cron
    ;;
  rhel|fedora)
    PM=dnf
    WEB_USER=nginx; WEB_GROUP=nginx
    # Remi "safe" parallel-install packages: php84-php-*, valid on every EL/Fedora release.
    PHP_BIN="/usr/bin/php${PHP_NODOT}"
    FPM_SERVICE="php${PHP_NODOT}-php-fpm"
    FPM_PASS="127.0.0.1:9000"
    PHP_INI_DIRS=("/etc/opt/remi/php${PHP_NODOT}/php.d")
    PG_SERVICE=postgresql
    SUPERVISOR_SERVICE=supervisord
    SUPERVISOR_CONF="/etc/supervisord.d/${APP_NAME}-worker.ini"
    CRON_SERVICE=crond
    ;;
esac

log "Detected $PRETTY_NAME ($FAMILY, package manager: $PM)"

pkg_update() {
  case "$PM" in
    apt) apt-get update -y ;;
    dnf) dnf makecache -y ;;
  esac
}
pkg_install() {
  case "$PM" in
    apt) apt-get install -y "$@" ;;
    dnf) dnf install -y "$@" ;;
  esac
}
# Best-effort install: one package at a time, warn instead of failing.
pkg_try() {
  local p
  for p in "$@"; do
    pkg_install "$p" >/dev/null 2>&1 || warn "optional package unavailable: $p"
  done
}
svc_enable() { systemctl enable --now "$1"; }

export DEBIAN_FRONTEND=noninteractive

# --------------------------------------------------------------------------
# Base packages + PHP repository
# --------------------------------------------------------------------------
setup_repos_apt() {
  pkg_update
  pkg_install ca-certificates curl gnupg lsb-release apt-transport-https
  if [[ "$FAMILY" == "ubuntu" ]]; then
    pkg_install software-properties-common
    add-apt-repository -y ppa:ondrej/php
  else
    local tmp; tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/keyring.deb" https://packages.sury.org/debsuryorg-archive-keyring.deb
    dpkg -i "$tmp/keyring.deb"
    rm -rf "$tmp"
    echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ ${VERSION_CODENAME} main" \
      > /etc/apt/sources.list.d/php.list
  fi
  pkg_update
}

setup_repos_dnf() {
  pkg_install ca-certificates curl
  local arch; arch="$(uname -m)"
  if [[ "$FAMILY" == "rhel" ]]; then
    # EPEL (supervisor, deps) + CodeReady/CRB (some -devel style deps for PHP libs)
    if [[ "$OS_ID" == "rhel" ]]; then
      pkg_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_MAJOR}.noarch.rpm" || warn "could not install EPEL"
      have subscription-manager && subscription-manager repos --enable "codeready-builder-for-rhel-${OS_MAJOR}-${arch}-rpms" \
        || warn "could not enable CodeReady Builder repo (is the system registered?)"
    else
      pkg_install epel-release || warn "could not install EPEL"
      pkg_install dnf-plugins-core
      have crb && crb enable || warn "could not enable CRB/PowerTools repo"
    fi
    pkg_install "https://rpms.remirepo.net/enterprise/remi-release-${OS_MAJOR}.rpm"
  else
    pkg_install "https://rpms.remirepo.net/fedora/remi-release-${OS_MAJOR}.rpm"
  fi
  pkg_update
}

# --------------------------------------------------------------------------
# PHP + web server + database + cache
# --------------------------------------------------------------------------
install_php() {
  log "Installing PHP ${PHP_VERSION}"
  if [[ "$PM" == apt ]]; then
    pkg_install "php${PHP_VERSION}-cli" "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-pgsql" \
      "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-curl" \
      "php${PHP_VERSION}-zip" "php${PHP_VERSION}-bcmath" "php${PHP_VERSION}-intl" "php${PHP_VERSION}-gd"
    pkg_try "php${PHP_VERSION}-opcache" "php${PHP_VERSION}-redis"
    update-alternatives --set php "/usr/bin/php${PHP_VERSION}" >/dev/null 2>&1 || true
  else
    local p="php${PHP_NODOT}-php"
    pkg_install "${p}-cli" "${p}-fpm" "${p}-pgsql" "${p}-mbstring" "${p}-xml" \
      "${p}-bcmath" "${p}-intl" "${p}-gd" "${p}-common"
    pkg_try "${p}-opcache" "${p}-pecl-zip" "${p}-pecl-redis6" "${p}-process"
    ln -sf "$PHP_BIN" /usr/local/bin/php
  fi

  local dir
  for dir in "${PHP_INI_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    cat > "$dir/99-laravel.ini" <<'EOF'
; Managed by laravel-prep.sh
expose_php = Off
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
opcache.enable = 1
opcache.memory_consumption = 256
opcache.max_accelerated_files = 20000
EOF
  done
}

configure_fpm() {
  if [[ "$PM" == dnf ]]; then
    local pool="/etc/opt/remi/php${PHP_NODOT}/php-fpm.d/www.conf"
    [[ -f "$pool" ]] || die "FPM pool file not found: $pool"
    sed -i -E \
      -e "s|^;?user = .*|user = ${WEB_USER}|" \
      -e "s|^;?group = .*|group = ${WEB_GROUP}|" \
      -e "s|^listen = .*|listen = ${FPM_PASS}|" \
      -e "s|^(listen\.acl_users)|;\1|" \
      "$pool"
  fi
  svc_enable "$FPM_SERVICE"
  systemctl restart "$FPM_SERVICE"
}

install_nginx() {
  log "Installing Nginx"
  pkg_install nginx
  local conf="/etc/nginx/conf.d/${APP_NAME}.conf"
  local listen_opts=""
  [[ "$DOMAIN" == "_" ]] && listen_opts=" default_server"

  if [[ -e "$conf" ]]; then
    warn "$conf already exists; leaving it untouched"
  else
    cat > "$conf" <<'EOF'
server {
    listen 80@LISTEN_OPTS@;
    listen [::]:80@LISTEN_OPTS@;
    server_name @DOMAIN@;
    root @APP_DIR@/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php;
    charset utf-8;
    client_max_body_size 64M;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ ^/index\.php(/|$) {
        fastcgi_pass @FPM_PASS@;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF
    sed -i \
      -e "s|@LISTEN_OPTS@|${listen_opts}|g" \
      -e "s|@DOMAIN@|${DOMAIN}|g" \
      -e "s|@APP_DIR@|${APP_DIR}|g" \
      -e "s|@FPM_PASS@|${FPM_PASS}|g" \
      "$conf"
  fi

  rm -f /etc/nginx/sites-enabled/default   # Debian/Ubuntu stock site
  nginx -t
  svc_enable nginx
  systemctl reload nginx
}

install_postgres() {
  log "Installing PostgreSQL"
  if [[ "$PM" == apt ]]; then
    pkg_install postgresql postgresql-contrib
  else
    # EL8 ships PostgreSQL 10 by default; pick a supported stream.
    if [[ "$FAMILY" == "rhel" && "$OS_MAJOR" -eq 8 ]]; then
      dnf -y module reset postgresql >/dev/null 2>&1 || true
      dnf -y module enable postgresql:16
    fi
    pkg_install postgresql-server postgresql-contrib
    if [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
      postgresql-setup --initdb
      # Make local TCP logins use password auth instead of ident.
      sed -i -E '/^host/ s/(ident|md5)[[:space:]]*$/scram-sha-256/' /var/lib/pgsql/data/pg_hba.conf
    fi
  fi
  svc_enable "$PG_SERVICE"
}

psql_admin() { (cd / && runuser -u postgres -- psql -v ON_ERROR_STOP=1 "$@"); }

create_database() {
  log "Creating PostgreSQL role '${DB_USER}' and database '${DB_NAME}'"
  local cred_dir=/root/.laravel-prep cred_file
  cred_file="$cred_dir/${APP_NAME}.env"
  mkdir -p "$cred_dir"; chmod 700 "$cred_dir"

  if [[ "$(psql_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'")" != "1" ]]; then
    local pw
    pw="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
    # stdin + :'pw' lets psql quote the value safely
    printf "CREATE ROLE %s LOGIN PASSWORD :'pw';\n" "$DB_USER" | psql_admin -v "pw=${pw}" >/dev/null
    umask 077
    cat > "$cred_file" <<EOF
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${pw}
EOF
    umask 022
    echo "Credentials saved to $cred_file (paste into your app's .env)"
  else
    echo "Role '${DB_USER}' already exists; password left unchanged."
  fi

  if [[ "$(psql_admin -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")" != "1" ]]; then
    psql_admin -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}" >/dev/null
  fi
}

install_redis() {
  log "Installing Redis"
  local svc=""
  if [[ "$PM" == apt ]]; then
    pkg_install redis-server; svc=redis-server
  elif pkg_install redis >/dev/null 2>&1; then
    svc=redis
  elif pkg_install valkey >/dev/null 2>&1; then
    svc=valkey      # EL10 ships Valkey (protocol compatible with Redis)
  fi
  if [[ -n "$svc" ]]; then svc_enable "$svc"; else warn "Redis/Valkey not available; skipping"; fi
}

# --------------------------------------------------------------------------
# Tooling: git, Composer, Node.js, Supervisor, cron
# --------------------------------------------------------------------------
install_tools() {
  log "Installing git, unzip, cron, Supervisor"
  if [[ "$PM" == apt ]]; then
    pkg_install git unzip xz-utils cron supervisor
  else
    pkg_install git unzip xz cronie
    pkg_try supervisor
  fi
  svc_enable "$CRON_SERVICE"
  if systemctl list-unit-files "${SUPERVISOR_SERVICE}.service" 2>/dev/null | grep -q "$SUPERVISOR_SERVICE"; then
    svc_enable "$SUPERVISOR_SERVICE"
  fi
}

install_composer() {
  log "Installing Composer"
  if have composer; then echo "Composer already installed"; return; fi
  local tmp expected actual; tmp="$(mktemp -d)"
  expected="$(curl -fsSL https://composer.github.io/installer.sig)"
  curl -fsSL -o "$tmp/installer.php" https://getcomposer.org/installer
  actual="$("$PHP_BIN" -r "echo hash_file('sha384', '$tmp/installer.php');")"
  [[ "$expected" == "$actual" ]] || die "Composer installer checksum mismatch"
  "$PHP_BIN" "$tmp/installer.php" --quiet --install-dir=/usr/local/bin --filename=composer
  rm -rf "$tmp"
}

install_node() {
  log "Installing Node.js ${NODE_MAJOR}"
  if have node && [[ "$(node -v | sed -E 's/^v([0-9]+).*/\1/')" == "$NODE_MAJOR" ]]; then
    echo "Node.js ${NODE_MAJOR} already installed"; return
  fi
  local arch base sums file tmp
  case "$(uname -m)" in
    x86_64)  arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) warn "Unsupported CPU for Node.js tarball: $(uname -m); skipping"; return ;;
  esac
  base="https://nodejs.org/dist/latest-v${NODE_MAJOR}.x"
  sums="$(curl -fsSL "$base/SHASUMS256.txt")"
  file="$(awk -v a="$arch" '$2 ~ "^node-v[0-9.]+-linux-" a "\\.tar\\.xz$" {print $2; exit}' <<<"$sums")"
  [[ -n "$file" ]] || { warn "Node.js ${NODE_MAJOR} tarball not found; skipping"; return; }
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/$file" "$base/$file"
  (cd "$tmp" && grep " ${file}\$" <<<"$sums" | sha256sum -c -)
  tar -xJf "$tmp/$file" -C /usr/local --strip-components=1 \
    --exclude='CHANGELOG.md' --exclude='LICENSE' --exclude='README.md'
  rm -rf "$tmp"
}

# --------------------------------------------------------------------------
# App skeleton: deploy user, directories, permissions, SELinux, worker, cron
# --------------------------------------------------------------------------
setup_app() {
  log "Preparing ${APP_DIR} and deploy user '${DEPLOY_USER}'"
  id "$DEPLOY_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$DEPLOY_USER"
  mkdir -p "$APP_DIR"
  chown "$DEPLOY_USER:$WEB_GROUP" "$APP_DIR"
  chmod 2750 "$APP_DIR"

  # Scheduler: runs only once an app has been deployed.
  cat > "/etc/cron.d/laravel-${APP_NAME}" <<EOF
# Managed by laravel-prep.sh
* * * * * ${WEB_USER} [ -f ${APP_DIR}/artisan ] && cd ${APP_DIR} && $(command -v php || echo "$PHP_BIN") artisan schedule:run >> /dev/null 2>&1
EOF
  chmod 644 "/etc/cron.d/laravel-${APP_NAME}"

  # Queue worker: defined but not started (autostart=false) until the app exists.
  if [[ -d "$(dirname "$SUPERVISOR_CONF")" ]]; then
    cat > "$SUPERVISOR_CONF" <<EOF
[program:${APP_NAME}-worker]
command=$(command -v php || echo "$PHP_BIN") ${APP_DIR}/artisan queue:work --sleep=3 --tries=3 --max-time=3600
directory=${APP_DIR}
user=${WEB_USER}
autostart=false
autorestart=true
stopwaitsecs=3600
numprocs=1
redirect_stderr=true
stdout_logfile=/var/log/${APP_NAME}-worker.log
EOF
  fi

  # SELinux (RHEL family): allow nginx/php-fpm to reach PostgreSQL/Redis and write storage.
  if have getenforce && [[ "$(getenforce)" != "Disabled" ]]; then
    log "Configuring SELinux"
    pkg_try policycoreutils-python-utils
    setsebool -P httpd_can_network_connect 1 || warn "setsebool httpd_can_network_connect failed"
    setsebool -P httpd_can_network_connect_db 1 || warn "setsebool httpd_can_network_connect_db failed"
    if have semanage; then
      local d
      for d in storage bootstrap/cache; do
        semanage fcontext -a -t httpd_sys_rw_content_t "${APP_DIR}/${d}(/.*)?" 2>/dev/null \
          || semanage fcontext -m -t httpd_sys_rw_content_t "${APP_DIR}/${d}(/.*)?" || true
      done
      restorecon -R "$APP_DIR" || true
    else
      warn "semanage not available; label storage/ and bootstrap/cache manually (see README)"
    fi
  fi
}

# --------------------------------------------------------------------------
# Firewall
# --------------------------------------------------------------------------
setup_firewall() {
  log "Configuring firewall"
  local ssh_port
  ssh_port="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  ssh_port="${ssh_port:-22}"
  if [[ "$PM" == apt ]]; then
    pkg_install ufw
    ufw allow "${ssh_port}/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
  else
    pkg_install firewalld
    svc_enable firewalld
    firewall-cmd --permanent --add-port="${ssh_port}/tcp"
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
  fi
}

# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------
if [[ "$PM" == apt ]]; then setup_repos_apt; else setup_repos_dnf; fi
install_php
configure_fpm
install_nginx
install_postgres
create_database
install_redis
install_tools
install_composer
[[ "$INSTALL_NODE" -eq 1 ]] && install_node
setup_app
[[ "$SETUP_FIREWALL" -eq 1 ]] && setup_firewall

log "Done"
cat <<EOF

  PHP        : $("$PHP_BIN" -r 'echo PHP_VERSION;')
  Nginx      : $(nginx -v 2>&1 | sed 's|.*/||')
  PostgreSQL : $(psql --version 2>/dev/null | awk '{print $3}')
  Composer   : $(composer --version 2>/dev/null | awk '{print $3}')
  Node.js    : $(node -v 2>/dev/null || echo skipped)

  App dir    : ${APP_DIR}  (owner ${DEPLOY_USER}, group ${WEB_GROUP})
  DB creds   : /root/.laravel-prep/${APP_NAME}.env
  Next steps : see README.md ("After the script runs")
EOF
