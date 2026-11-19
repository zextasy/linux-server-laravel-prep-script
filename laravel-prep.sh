#!/usr/bin/env bash
#
# laravel-prep.sh - one-time setup of a Linux server for hosting Laravel apps.
#
# Installs and configures: PHP (+ FPM and the extensions Laravel needs), Nginx,
# PostgreSQL, Redis, Composer, Node.js, Supervisor, cron, SELinux booleans and a
# firewall. It does NOT set up any individual app: run `laravel-app` (installed
# by this script from laravel-app.sh) from each app's directory for that.
#
# Supported: Ubuntu, Debian, RHEL, CentOS Stream, Rocky Linux, AlmaLinux,
#            Oracle Linux, Fedora (all systemd based).
#
# Usage:  sudo ./laravel-prep.sh [options]      (see --help)

set -Eeuo pipefail
trap 'echo "ERROR: line $LINENO: command failed: $BASH_COMMAND" >&2' ERR
# sudo on RHEL-family systems resets PATH to one without /usr/local, where Composer,
# Node.js and laravel-app are installed. Make sure this script can always find them.
export PATH="/usr/local/sbin:/usr/local/bin:${PATH}"

# --------------------------------------------------------------------------
# Defaults (override with flags or environment variables)
# --------------------------------------------------------------------------
PHP_VERSION="${PHP_VERSION:-8.4}"
NODE_MAJOR="${NODE_MAJOR:-22}"
INSTALL_NODE=1
SETUP_FIREWALL=1

usage() {
  cat <<EOF
Usage: sudo $0 [options]

  --php-version X.Y     PHP version to install            (default: $PHP_VERSION)
  --node-version N      Node.js major version             (default: $NODE_MAJOR)
  --no-node             Skip Node.js
  --skip-firewall       Do not touch the firewall
  -h, --help            Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --php-version)   PHP_VERSION="${2:?}"; shift 2 ;;
    --node-version)  NODE_MAJOR="${2:?}"; shift 2 ;;
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

# Every value below ends up in package names and config files, so keep them strict.
[[ "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]     || die "Invalid --php-version: $PHP_VERSION"
[[ "$NODE_MAJOR" =~ ^[0-9]+$ ]]              || die "Invalid --node-version: $NODE_MAJOR"

PHP_NODOT="${PHP_VERSION/./}"

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
    SUPERVISOR_CONF_DIR=/etc/supervisor/conf.d; SUPERVISOR_CONF_EXT=conf
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
    SUPERVISOR_CONF_DIR=/etc/supervisord.d; SUPERVISOR_CONF_EXT=ini
    CRON_SERVICE=crond
    ;;
esac

log "Detected $PRETTY_NAME ($FAMILY, package manager: $PM)"

pkg_update() {
  case "$PM" in
    apt) apt-get update -y ;;
    dnf) dnf makecache -y || warn "could not refresh all repository metadata; continuing" ;;
  esac
}
pkg_install() {
  case "$PM" in
    apt) apt-get -o Acquire::Retries=5 install -y "$@" ;;
    dnf) dnf install -y --setopt=retries=5 "$@" ;;
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
  pkg_install ca-certificates
  have curl || pkg_install curl   # EL images often ship curl-minimal, which conflicts with curl
  local arch; arch="$(uname -m)"
  if [[ "$FAMILY" == "rhel" ]]; then
    # EPEL (supervisor, deps) + CodeReady/CRB (some -devel style deps for PHP libs)
    if [[ "$OS_ID" == "rhel" ]]; then
      pkg_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_MAJOR}.noarch.rpm" || warn "could not install EPEL"
      have subscription-manager && subscription-manager repos --enable "codeready-builder-for-rhel-${OS_MAJOR}-${arch}-rpms" \
        || warn "could not enable CodeReady Builder repo (is the system registered?)"
    elif [[ "$OS_ID" == "ol" ]]; then
      # Oracle Linux has its own EPEL package and CodeReady Builder repo id.
      pkg_install "oracle-epel-release-el${OS_MAJOR}" || warn "could not install EPEL"
      pkg_install dnf-plugins-core
      # Installing the package is not enough: the repos may be present but disabled, and
      # PHP's gd extension needs libraries (libavif, libraqm, ...) from these two repos.
      local r
      for r in "ol${OS_MAJOR}_developer_EPEL" "ol${OS_MAJOR}_codeready_builder"; do
        dnf config-manager --set-enabled "$r" || warn "could not enable the $r repo"
      done
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
  if [[ "$PM" == dnf ]]; then
    # Fail early with an explanation instead of a bare dependency error.
    dnf_php_hint='PHP failed to install. On RHEL-family systems this usually means the EPEL and/or CodeReady Builder (CRB) repositories are not enabled (check: dnf repolist), or Remi has no build for this OS/architecture.'
  fi
  if [[ "$PM" == apt ]]; then
    pkg_install "php${PHP_VERSION}-cli" "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-pgsql" \
      "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-xml" "php${PHP_VERSION}-curl" \
      "php${PHP_VERSION}-zip" "php${PHP_VERSION}-bcmath" "php${PHP_VERSION}-intl" "php${PHP_VERSION}-gd"
    pkg_try "php${PHP_VERSION}-opcache" "php${PHP_VERSION}-redis"
    update-alternatives --set php "/usr/bin/php${PHP_VERSION}" >/dev/null 2>&1 || true
  else
    local p="php${PHP_NODOT}-php"
    pkg_install "${p}-cli" "${p}-fpm" "${p}-pgsql" "${p}-mbstring" "${p}-xml" \
      "${p}-bcmath" "${p}-intl" "${p}-gd" "${p}-common" || die "$dnf_php_hint"
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
  rm -f /etc/nginx/sites-enabled/default   # Debian/Ubuntu stock site; app vhosts are added by laravel-app
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
  if systemctl cat "${SUPERVISOR_SERVICE}.service" >/dev/null 2>&1; then
    svc_enable "$SUPERVISOR_SERVICE"
  fi
}

install_composer() {
  log "Installing Composer"
  local existing; existing="$(command -v composer || true)"

  # A Composer we installed earlier: bring it up to the current stable release.
  # (--stable also moves an old 2.2 LTS install onto the normal release channel.)
  if [[ "$existing" == /usr/local/bin/composer ]]; then
    echo "Composer found ($(COMPOSER_ALLOW_SUPERUSER=1 composer --version 2>/dev/null | head -1)); updating"
    COMPOSER_ALLOW_SUPERUSER=1 composer self-update --stable --no-interaction \
      || warn "composer self-update failed; keeping the existing version"
    return 0
  fi
  [[ -z "$existing" ]] || warn "found Composer at $existing (not managed by this script); installing a current copy in /usr/local/bin, which takes precedence"

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
# SELinux (RHEL family): let nginx/php-fpm reach PostgreSQL/Redis. Per-app file
# labels are applied by laravel-app.
# --------------------------------------------------------------------------
configure_selinux() {
  have getenforce && [[ "$(getenforce)" != "Disabled" ]] || return 0
  log "Configuring SELinux"
  pkg_try policycoreutils-python-utils
  setsebool -P httpd_can_network_connect 1 || warn "setsebool httpd_can_network_connect failed"
  setsebool -P httpd_can_network_connect_db 1 || warn "setsebool httpd_can_network_connect_db failed"
}

# --------------------------------------------------------------------------
# sudo PATH (RHEL family): its secure_path lacks /usr/local, so `sudo laravel-app`,
# `sudo -u deploy composer` and friends would say "command not found". Add a drop-in.
# --------------------------------------------------------------------------
fix_sudo_path() {
  [[ "$PM" == dnf ]] || return 0      # Debian/Ubuntu already include /usr/local in secure_path
  have visudo || return 0             # sudo not installed: nothing to fix
  local tmp; tmp="$(mktemp)"
  echo 'Defaults secure_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' > "$tmp"
  if visudo -cf "$tmp" >/dev/null 2>&1; then
    install -m 0440 -o root -g root "$tmp" /etc/sudoers.d/laravel-prep-path
    echo "Added /etc/sudoers.d/laravel-prep-path so sudo can find /usr/local/bin and /usr/local/sbin"
  else
    warn "could not validate the sudoers drop-in; sudo may not find laravel-app/composer/node (use their full /usr/local paths)"
  fi
  rm -f "$tmp"
}

# --------------------------------------------------------------------------
# Hand-off to laravel-app: record what was detected, install the per-app script
# --------------------------------------------------------------------------
write_state() {
  log "Recording server settings in /etc/laravel-prep/server.conf"
  mkdir -p /etc/laravel-prep
  {
    echo "# Written by laravel-prep.sh and read by laravel-app. Do not edit by hand."
    for v in FAMILY PM WEB_USER WEB_GROUP PHP_VERSION PHP_BIN FPM_PASS \
             SUPERVISOR_SERVICE SUPERVISOR_CONF_DIR SUPERVISOR_CONF_EXT; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } > /etc/laravel-prep/server.conf
  chmod 644 /etc/laravel-prep/server.conf

  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
  if [[ -n "$here" && -f "$here/laravel-app.sh" ]]; then
    install -m 0755 "$here/laravel-app.sh" /usr/local/sbin/laravel-app
    echo "Installed /usr/local/sbin/laravel-app"
  else
    warn "laravel-app.sh not found next to this script; install it manually as /usr/local/sbin/laravel-app"
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
install_nginx    # before configure_fpm: on RHEL it creates the 'nginx' user the FPM pool runs as
configure_fpm
install_postgres
install_redis
install_tools
install_composer
[[ "$INSTALL_NODE" -eq 1 ]] && install_node
configure_selinux
[[ "$SETUP_FIREWALL" -eq 1 ]] && setup_firewall
write_state
fix_sudo_path

log "Done"

# Version lookups must never abort or print errors: a missing tool just shows "not found".
v_php="$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null || echo 'not found')"
v_nginx=""; have nginx && v_nginx="$(nginx -v 2>&1 | sed 's|.*/||' || true)"
v_pg="$(psql --version 2>/dev/null | awk '{print $3}' || true)"
v_composer="$(composer --version 2>/dev/null | awk '{print $3}' || true)"
v_node="$(node -v 2>/dev/null || true)"

cat <<EOF

  PHP        : ${v_php}
  Nginx      : ${v_nginx:-not found}
  PostgreSQL : ${v_pg:-not found}
  Composer   : ${v_composer:-not found}
  Node.js    : ${v_node:-$([[ "$INSTALL_NODE" -eq 1 ]] && echo "not found" || echo skipped)}

  Next step  : cd into a Laravel app directory and run:  sudo laravel-app --domain example.com
EOF
