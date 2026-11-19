#!/usr/bin/env bash
#
# laravel-app.sh - set up ONE Laravel app on a server prepared by laravel-prep.sh.
#
# Run it from the app's directory (the one containing `artisan`), as root. Run it
# once per app; every app gets its own Nginx vhost, PostgreSQL role + database,
# scheduler cron entry and queue-worker definition, all named after the app.
#
#   cd /var/www/myapp && sudo laravel-app --domain example.com
#   cd /var/www/myapp && sudo laravel-app --remove          # undo it again
#
# laravel-prep.sh installs this script as /usr/local/sbin/laravel-app.

set -Eeuo pipefail
trap 'echo "ERROR: line $LINENO: command failed: $BASH_COMMAND" >&2' ERR

STATE_FILE=/etc/laravel-prep/server.conf

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------------------
# Options
# --------------------------------------------------------------------------
APP_PATH=""
APP_NAME=""
DOMAIN="_"
DB_NAME=""
DB_USER=""
SETUP_DB=1
SETUP_SCHEDULER=1
SETUP_WORKER=1
START_WORKER=0
UPDATE_ENV=0
FORCE=0
REMOVE=0
DROP_DB=0
ASSUME_YES=0

usage() {
  cat <<EOF
Usage: cd /path/to/laravel-app && sudo $(basename "$0") [options]

  --domain DOMAIN     Nginx server_name              (default: catch-all; only one app may use it)
  --name NAME         App name for vhost/DB/cron     (default: derived from the directory name)
  --path DIR          App directory                  (default: current directory)
  --db-name NAME      PostgreSQL database            (default: app name)
  --db-user NAME      PostgreSQL role                (default: app name)
  --update-env        Write the DB_* settings into the app's .env (only for a newly created role)
  --no-db             Skip PostgreSQL role/database
  --no-scheduler      Skip the schedule:run cron entry
  --no-worker         Skip the Supervisor queue-worker definition
  --start-worker      Start the queue worker now (default: defined but not started)
  --force             Proceed even if no artisan file is found
  --remove            Undo the setup of this app: removes its Nginx vhost, cron entry and
                      queue worker. The app's files and its database are kept.
  --drop-db           With --remove: also DROP the app's database and role and delete the
                      saved credentials (asks you to type the database name, or pass --yes)
  --yes               Skip the --drop-db confirmation prompt
  -h, --help          Show this help

Group ownership of the app directory is changed to the web server's group, world
write access is removed, and storage/ and bootstrap/cache are made group-writable.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)        DOMAIN="${2:?}"; shift 2 ;;
    --name)          APP_NAME="${2:?}"; shift 2 ;;
    --path)          APP_PATH="${2:?}"; shift 2 ;;
    --db-name)       DB_NAME="${2:?}"; shift 2 ;;
    --db-user)       DB_USER="${2:?}"; shift 2 ;;
    --update-env)    UPDATE_ENV=1; shift ;;
    --no-db)         SETUP_DB=0; shift ;;
    --no-scheduler)  SETUP_SCHEDULER=0; shift ;;
    --no-worker)     SETUP_WORKER=0; shift ;;
    --start-worker)  START_WORKER=1; shift ;;
    --force)         FORCE=1; shift ;;
    --remove)        REMOVE=1; shift ;;
    --drop-db)       DROP_DB=1; shift ;;
    --yes|-y)        ASSUME_YES=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run as root (e.g. sudo $(basename "$0"))"
[[ "$DROP_DB" -eq 0 || "$REMOVE" -eq 1 ]] || die "--drop-db only makes sense together with --remove"

# --------------------------------------------------------------------------
# Server settings recorded by laravel-prep.sh
# --------------------------------------------------------------------------
[[ -r "$STATE_FILE" ]] || die "$STATE_FILE not found. Run laravel-prep.sh on this server first."
# shellcheck disable=SC1090
. "$STATE_FILE"
: "${WEB_USER:?}" "${WEB_GROUP:?}" "${PHP_BIN:?}" "${FPM_PASS:?}"

# --------------------------------------------------------------------------
# Resolve and validate the app
# --------------------------------------------------------------------------
APP_DIR="$(realpath -m "${APP_PATH:-$PWD}")"
if [[ "$REMOVE" -eq 0 ]]; then
  [[ -d "$APP_DIR" ]] || die "Not a directory: $APP_DIR"
  [[ "$APP_DIR" != "/" ]] || die "Refusing to use / as the app directory"
  # The path ends up in Nginx, cron and Supervisor files, so keep it plain.
  [[ "$APP_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "App path may only contain letters, digits and . _ / - (got: $APP_DIR)"

  if [[ ! -f "$APP_DIR/artisan" || ! -d "$APP_DIR/public" ]]; then
    [[ "$FORCE" -eq 1 ]] || die "$APP_DIR doesn't look like a Laravel app (no artisan or public/). Run from the app directory, or use --force."
    warn "No artisan/public found in $APP_DIR; continuing because of --force"
  fi
fi

NAME_GIVEN="$APP_NAME"
if [[ -z "$APP_NAME" ]]; then
  APP_NAME="$(basename "$APP_DIR" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_]+/_/g; s/^_+|_+$//g')"
  [[ "$APP_NAME" =~ ^[a-z] ]] || APP_NAME="app_${APP_NAME}"
fi
[[ "$APP_NAME" =~ ^[a-z][a-z0-9_]{0,39}$ ]] || die "--name must match ^[a-z][a-z0-9_]{0,39}\$ (got: $APP_NAME)"
[[ "$DOMAIN" =~ ^[A-Za-z0-9._-]+$ ]]        || die "Invalid --domain: $DOMAIN"
DB_NAME_GIVEN="$DB_NAME"; DB_USER_GIVEN="$DB_USER"
DB_NAME="${DB_NAME:-$APP_NAME}"
DB_USER="${DB_USER:-$APP_NAME}"
[[ "$DB_NAME" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "--db-name must match ^[a-z_][a-z0-9_]*$"
[[ "$DB_USER" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "--db-user must match ^[a-z_][a-z0-9_]*$"

[[ "$REMOVE" -eq 1 ]] || log "Setting up '${APP_NAME}' in ${APP_DIR}"

# --------------------------------------------------------------------------
# Permissions: web group can read the app and write storage/ + bootstrap/cache
# --------------------------------------------------------------------------
setup_permissions() {
  log "Setting permissions (group: ${WEB_GROUP})"
  local d owner
  owner="$(stat -c %U "$APP_DIR")"
  # Create any missing writable dirs, owned by whoever owns the app (not root).
  for d in storage bootstrap/cache; do
    [[ -d "$APP_DIR/$d" ]] || { mkdir -p "$APP_DIR/$d"; chown "$owner" "$APP_DIR/$d"; }
  done
  chgrp -R "$WEB_GROUP" "$APP_DIR"
  chmod -R g+rX,o-w "$APP_DIR"       # web group can read; nobody else can write
  for d in storage bootstrap/cache; do
    chmod -R ug+rwX "$APP_DIR/$d"
    find "$APP_DIR/$d" -type d -exec chmod g+s {} +
  done
  # .env holds secrets: readable by owner and the web group only.
  [[ -f "$APP_DIR/.env" ]] && chmod 640 "$APP_DIR/.env"

  # nginx/php-fpm must be able to walk down to the app (a typical problem under /home).
  if ! runuser -u "$WEB_USER" -- test -r "$APP_DIR/public" 2>/dev/null; then
    warn "User '${WEB_USER}' cannot read ${APP_DIR}/public. A parent directory is probably not traversable"
    warn "(e.g. /home/<user> is mode 700). Move the app to /var/www or run: chmod o+x <each parent directory>"
  fi
}

# --------------------------------------------------------------------------
# SELinux file labels (no-op where SELinux is off or absent)
# --------------------------------------------------------------------------
setup_selinux() {
  have getenforce && [[ "$(getenforce)" != "Disabled" ]] || return 0
  log "Applying SELinux labels"
  if ! have semanage; then
    warn "semanage not available; label ${APP_DIR} (httpd_sys_content_t) and storage/, bootstrap/cache (httpd_sys_rw_content_t) manually"
    return 0
  fi
  semanage fcontext -a -t httpd_sys_content_t "${APP_DIR}(/.*)?" 2>/dev/null \
    || semanage fcontext -m -t httpd_sys_content_t "${APP_DIR}(/.*)?" || true
  local d
  for d in storage bootstrap/cache; do
    semanage fcontext -a -t httpd_sys_rw_content_t "${APP_DIR}/${d}(/.*)?" 2>/dev/null \
      || semanage fcontext -m -t httpd_sys_rw_content_t "${APP_DIR}/${d}(/.*)?" || true
  done
  restorecon -R "$APP_DIR" || true
}

# --------------------------------------------------------------------------
# Database
# --------------------------------------------------------------------------
psql_admin() { (cd / && runuser -u postgres -- psql -v ON_ERROR_STOP=1 "$@"); }

DB_PASSWORD_NEW=""
create_database() {
  log "Creating PostgreSQL role '${DB_USER}' and database '${DB_NAME}'"
  have psql || die "PostgreSQL client not found; was laravel-prep.sh run on this server?"
  local cred_dir=/root/.laravel-prep cred_file
  cred_file="$cred_dir/${APP_NAME}.env"
  mkdir -p "$cred_dir"; chmod 700 "$cred_dir"

  if [[ "$(psql_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'")" != "1" ]]; then
    local pw
    pw="$(head -c 96 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | cut -c1-32)"
    # stdin + :'pw' lets psql quote the value safely.
    # Force scram hashing: PostgreSQL < 14 defaults to md5, which pg_hba's scram-sha-256 would reject.
    printf "SET password_encryption = 'scram-sha-256';\nCREATE ROLE %s LOGIN PASSWORD :'pw';\n" "$DB_USER" \
      | psql_admin -v "pw=${pw}" >/dev/null
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
    DB_PASSWORD_NEW="$pw"
    echo "Credentials saved to $cred_file"
  else
    echo "Role '${DB_USER}' already exists; password left unchanged."
  fi

  if [[ "$(psql_admin -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")" != "1" ]]; then
    psql_admin -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}" >/dev/null
  fi
}

# Set KEY=VALUE in .env, replacing an existing or commented-out line, else appending.
# Rewrites via cat so the file keeps its owner and mode.
set_env_key() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"
  if grep -qE "^#?[[:space:]]*${key}=" "$file"; then
    sed -E "s|^#?[[:space:]]*${key}=.*|${key}=${value}|" "$file" > "$tmp"
  else
    { cat "$file"; echo "${key}=${value}"; } > "$tmp"
  fi
  cat "$tmp" > "$file"; rm -f "$tmp"
}

update_env_file() {
  local env="$APP_DIR/.env"
  [[ -f "$env" ]] || { warn "--update-env: $env not found; copy .env.example to .env first"; return 0; }
  [[ -n "$DB_PASSWORD_NEW" ]] || { warn "--update-env: role already existed, so its password is unknown; .env left alone"; return 0; }
  set_env_key "$env" DB_CONNECTION pgsql
  set_env_key "$env" DB_HOST 127.0.0.1
  set_env_key "$env" DB_PORT 5432
  set_env_key "$env" DB_DATABASE "$DB_NAME"
  set_env_key "$env" DB_USERNAME "$DB_USER"
  set_env_key "$env" DB_PASSWORD "$DB_PASSWORD_NEW"
  echo "Updated DB_* settings in $env"
}

# --------------------------------------------------------------------------
# Nginx vhost
# --------------------------------------------------------------------------
setup_vhost() {
  log "Configuring Nginx for ${DOMAIN}"
  have nginx || die "nginx not found; was laravel-prep.sh run on this server?"
  local conf="/etc/nginx/conf.d/${APP_NAME}.conf"

  if [[ -e "$conf" ]]; then
    warn "$conf already exists; leaving it untouched (delete it and re-run to regenerate)"
    return 0
  fi

  local listen_opts=""
  if [[ "$DOMAIN" == "_" ]]; then
    if grep -qs "default_server" /etc/nginx/conf.d/*.conf; then
      die "Another app already uses the catch-all (default_server) vhost. Pass --domain for this one."
    fi
    listen_opts=" default_server"
  fi
  local listen6=""
  # Only listen on IPv6 if the kernel has it (nginx fails to start otherwise).
  [[ -s /proc/net/if_inet6 ]] && listen6="    listen [::]:80${listen_opts};"

  cat > "$conf" <<'EOF'
server {
    listen 80@LISTEN_OPTS@;
@LISTEN6@
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
    -e "s|^@LISTEN6@\$|${listen6}|" \
    -e "s|@LISTEN_OPTS@|${listen_opts}|g" \
    -e "s|@DOMAIN@|${DOMAIN}|g" \
    -e "s|@APP_DIR@|${APP_DIR}|g" \
    -e "s|@FPM_PASS@|${FPM_PASS}|g" \
    "$conf"

  # Never leave nginx with a broken config: roll the new vhost back on failure.
  if ! nginx -t; then
    rm -f "$conf"
    die "nginx rejected the new vhost; it was removed"
  fi
  systemctl reload nginx
}

# --------------------------------------------------------------------------
# Scheduler and queue worker
# --------------------------------------------------------------------------
setup_scheduler() {
  log "Installing scheduler cron entry"
  cat > "/etc/cron.d/laravel-${APP_NAME}" <<EOF
# Managed by laravel-app (${APP_DIR})
* * * * * ${WEB_USER} cd ${APP_DIR} && ${PHP_BIN} artisan schedule:run >> /dev/null 2>&1
EOF
  chmod 644 "/etc/cron.d/laravel-${APP_NAME}"
}

setup_worker() {
  log "Defining Supervisor queue worker '${APP_NAME}-worker'"
  if [[ ! -d "${SUPERVISOR_CONF_DIR:-}" ]]; then
    warn "Supervisor config dir not found (${SUPERVISOR_CONF_DIR:-unset}); skipping the queue worker"
    return 0
  fi
  local autostart=false
  [[ "$START_WORKER" -eq 1 ]] && autostart=true
  cat > "${SUPERVISOR_CONF_DIR}/${APP_NAME}-worker.${SUPERVISOR_CONF_EXT}" <<EOF
[program:${APP_NAME}-worker]
command=${PHP_BIN} ${APP_DIR}/artisan queue:work --sleep=3 --tries=3 --max-time=3600
directory=${APP_DIR}
user=${WEB_USER}
autostart=${autostart}
autorestart=true
stopwaitsecs=3600
numprocs=1
redirect_stderr=true
stdout_logfile=/var/log/${APP_NAME}-worker.log
EOF
  if [[ "$START_WORKER" -eq 1 ]] && have supervisorctl; then
    supervisorctl reread >/dev/null && supervisorctl update >/dev/null \
      && echo "Queue worker started" || warn "could not start the worker via supervisorctl"
  fi
}

# --------------------------------------------------------------------------
# Remove: undo what this script set up for one app (never touches the app's code)
# --------------------------------------------------------------------------
remove_app() {
  local conf="/etc/nginx/conf.d/${APP_NAME}.conf"
  local cron="/etc/cron.d/laravel-${APP_NAME}"
  local sup="${SUPERVISOR_CONF_DIR:-/nonexistent}/${APP_NAME}-worker.${SUPERVISOR_CONF_EXT:-conf}"
  local cred_file="/root/.laravel-prep/${APP_NAME}.env"
  local found=0 dir_known=0
  # The app directory is trustworthy if it came from --path, from the current directory
  # (no --name given), or from the vhost; with only --name and no vhost it is just $PWD.
  [[ -n "$APP_PATH" || -z "$NAME_GIVEN" ]] && dir_known=1

  # Prefer the names the app was actually created with over the defaults.
  if [[ "$DROP_DB" -eq 1 && -r "$cred_file" ]]; then
    local n u
    n="$(sed -n 's/^DB_DATABASE=//p' "$cred_file")"; u="$(sed -n 's/^DB_USERNAME=//p' "$cred_file")"
    [[ -z "$DB_NAME_GIVEN" && "$n" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] && DB_NAME="$n"
    [[ -z "$DB_USER_GIVEN" && "$u" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] && DB_USER="$u"
  fi

  # Confirm before anything is touched, so declining leaves everything intact.
  if [[ "$DROP_DB" -eq 1 ]]; then
    case "$DB_NAME" in postgres|template0|template1) die "Refusing to drop the '${DB_NAME}' database" ;; esac
    [[ "$DB_USER" != "postgres" ]] || die "Refusing to drop the 'postgres' role"
    if [[ "$ASSUME_YES" -ne 1 ]]; then
      [[ -t 0 ]] || die "--drop-db needs --yes when not run from a terminal"
      local ans
      read -r -p "This permanently deletes database '${DB_NAME}' and role '${DB_USER}'. Type the database name to confirm: " ans
      [[ "$ans" == "$DB_NAME" ]] || die "Confirmation did not match; nothing was removed"
    fi
  fi

  log "Removing '${APP_NAME}'"

  # Recover the app directory from the vhost (needed for the SELinux rules).
  if [[ -f "$conf" ]]; then
    local root
    root="$(awk '$1=="root"{gsub(";","",$2); print $2; exit}' "$conf")"
    if [[ "${root%/public}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then APP_DIR="${root%/public}"; dir_known=1; fi
  fi

  if [[ -f "$sup" ]]; then
    found=1
    if have supervisorctl; then
      supervisorctl stop "${APP_NAME}-worker" >/dev/null 2>&1 || true
    fi
    rm -f "$sup"
    if have supervisorctl; then
      { supervisorctl reread && supervisorctl update; } >/dev/null 2>&1 || warn "supervisorctl could not reload its config"
    fi
    echo "Removed queue worker"
  fi

  if [[ -f "$cron" ]]; then
    found=1; rm -f "$cron"; echo "Removed $cron"
  fi

  if [[ -f "$conf" ]]; then
    found=1; rm -f "$conf"; echo "Removed $conf"
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx
    else
      warn "nginx config test fails for a reason unrelated to this app; not reloading. Run: nginx -t"
    fi
  fi

  # SELinux: drop the file-context rules added for this app (the labels on disk are left as they are).
  if [[ "$dir_known" -eq 1 && "$APP_DIR" =~ ^/[A-Za-z0-9._/-]+$ && "$APP_DIR" != "/" ]] \
     && have getenforce && [[ "$(getenforce)" != "Disabled" ]] && have semanage; then
    local pat
    for pat in "${APP_DIR}(/.*)?" "${APP_DIR}/storage(/.*)?" "${APP_DIR}/bootstrap/cache(/.*)?"; do
      semanage fcontext -d "$pat" 2>/dev/null || true
    done
    [[ -d "$APP_DIR" ]] && { restorecon -R "$APP_DIR" || true; }
  fi

  if [[ "$DROP_DB" -eq 1 ]]; then
    have psql || die "PostgreSQL client not found"
    log "Dropping database '${DB_NAME}' and role '${DB_USER}'"
    psql_admin -c "DROP DATABASE IF EXISTS ${DB_NAME} WITH (FORCE)" >/dev/null \
      || warn "could not drop database ${DB_NAME}"
    psql_admin -c "DROP ROLE IF EXISTS ${DB_USER}" >/dev/null \
      || warn "could not drop role ${DB_USER} (does it own other objects?)"
    rm -f "$cred_file"
    found=1
  fi

  [[ "$found" -eq 1 ]] || die "Nothing found to remove for '${APP_NAME}'. Check the name (see /etc/nginx/conf.d/) or pass --name."

  log "Done"
  cat <<EOF

  Removed    : vhost, scheduler and queue worker for '${APP_NAME}'$([[ "$DROP_DB" -eq 1 ]] && echo ", database ${DB_NAME} and role ${DB_USER}")
  Kept       : the app's files$([[ "$DROP_DB" -eq 0 ]] && echo ", its PostgreSQL database/role and /root/.laravel-prep/${APP_NAME}.env (use --drop-db to delete them)"), /var/log/${APP_NAME}-worker.log, and the group/permission changes
EOF
}

# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------
if [[ "$REMOVE" -eq 1 ]]; then
  remove_app
  exit 0
fi

setup_permissions
setup_selinux
if [[ "$SETUP_DB" -eq 1 ]]; then
  create_database
  [[ "$UPDATE_ENV" -eq 1 ]] && update_env_file
fi
setup_vhost
[[ "$SETUP_SCHEDULER" -eq 1 ]] && setup_scheduler
[[ "$SETUP_WORKER" -eq 1 ]] && setup_worker

log "Done"
cat <<EOF

  App        : ${APP_NAME}  (${APP_DIR})
  URL        : http://${DOMAIN/#_/<server-ip>}/
  Database   : ${DB_NAME} (role ${DB_USER})$([[ "$SETUP_DB" -eq 1 ]] && echo "  creds: /root/.laravel-prep/${APP_NAME}.env")
  Scheduler  : $([[ "$SETUP_SCHEDULER" -eq 1 ]] && echo "/etc/cron.d/laravel-${APP_NAME}" || echo skipped)
  Worker     : $([[ "$SETUP_WORKER" -eq 1 ]] && echo "${APP_NAME}-worker $([[ "$START_WORKER" -eq 1 ]] && echo '(started)' || echo '(defined, not started: supervisorctl reread && supervisorctl update && supervisorctl start '"${APP_NAME}"'-worker)')" || echo skipped)

  Remember: set DB_* in .env, then run migrations (php artisan migrate --force).
EOF
