#!/usr/bin/env bash
#
# discover.sh — Scans a Laravel app to determine which Supervisor
# programs are needed and generates /etc/supervisor/conf.d/laravel.conf.
#
set -euo pipefail

APP_DIR="${1:-/var/www/html}"
CONF_DIR="/etc/supervisor/conf.d"
CONF_FILE="$CONF_DIR/laravel.conf"

mkdir -p "$CONF_DIR"
: > "$CONF_FILE"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pkg() {
  jq -r ".require[\"$1\"] // empty" "$APP_DIR/composer.json" 2>/dev/null
}

add_program() {
  local name="$1"
  local command="$2"
  cat >> "$CONF_FILE" <<EOF

[program:${name}]
command=${command}
directory=${APP_DIR}
autostart=true
autorestart=true
user=www-data
redirect_stderr=true
stdout_logfile=/var/log/supervisor/${name}.log
stopwaitsecs=60
EOF
  echo "  [discover] + $name: $command"
}

# Supervisor programs that must run as root
add_program_root() {
  local name="$1"
  local command="$2"
  cat >> "$CONF_FILE" <<EOF

[program:${name}]
command=${command}
autostart=true
autorestart=true
user=root
redirect_stderr=true
stdout_logfile=/var/log/supervisor/${name}.log
stopwaitsecs=10
EOF
  echo "  [discover] + $name (root): $command"
}

parse_procfile() {
  echo "[discover] Procfile found — using developer-defined processes (skipping auto-discovery)"
  while IFS=: read -r name command; do
    name="$(echo "$name" | xargs)"
    command="$(echo "$command" | xargs)"
    [[ -z "$name" || -z "$command" ]] && continue
    add_program "$name" "$command"
  done < "$APP_DIR/Procfile"
}

# ---------------------------------------------------------------------------
# Detect packages from composer.json
# ---------------------------------------------------------------------------

OCTANE=$(pkg "laravel/octane")
HORIZON=$(pkg "laravel/horizon")
REVERB=$(pkg "laravel/reverb")
WS_OLD=$(pkg "beyondcode/laravel-websockets")
NIGHTWATCH=$(pkg "laravel/nightwatch")
PULSE=$(pkg "laravel/pulse")
TELESCOPE=$(pkg "laravel/telescope")
SANCTUM=$(pkg "laravel/sanctum")
CASHIER=$(pkg "laravel/cashier-stripe")
[ -z "$CASHIER" ] && CASHIER=$(pkg "laravel/cashier")
SCOUT=$(pkg "laravel/scout")
BACKUP=$(pkg "spatie/laravel-backup")
HEALTH=$(pkg "spatie/laravel-health")
ACTIVITYLOG=$(pkg "spatie/laravel-activitylog")
MEDIALIBRARY=$(pkg "spatie/laravel-medialibrary")

# ---------------------------------------------------------------------------
# Detect files
# ---------------------------------------------------------------------------

HAS_JOBS=""
if find "$APP_DIR/app/Jobs" "$APP_DIR/app/Listeners" -name "*.php" 2>/dev/null | head -1 | grep -q .; then
  HAS_JOBS="yes"
fi

NEEDS_SCHEDULER=""
NEEDS_QUEUE=""

[ -f "$APP_DIR/app/Console/Kernel.php" ] && NEEDS_SCHEDULER="yes"
[ -f "$APP_DIR/routes/console.php" ] && NEEDS_SCHEDULER="yes"

# Packages that force-enable the scheduler
for p in "$TELESCOPE" "$SANCTUM" "$BACKUP" "$HEALTH" "$ACTIVITYLOG" "$MEDIALIBRARY"; do
  [ -n "$p" ] && NEEDS_SCHEDULER="yes"
done

# Packages that force-enable a queue worker
for p in "$MEDIALIBRARY" "$BACKUP" "$SCOUT"; do
  [ -n "$p" ] && NEEDS_QUEUE="yes"
done
[ -n "$HAS_JOBS" ] && NEEDS_QUEUE="yes"

# ---------------------------------------------------------------------------
# Procfile override — skip all auto-discovery
# ---------------------------------------------------------------------------

if [ -f "$APP_DIR/Procfile" ]; then
  parse_procfile
  exit 0
fi

echo "[discover] Scanning $APP_DIR for services..."

# ---------------------------------------------------------------------------
# Web server: Octane replaces php-fpm + nginx
# ---------------------------------------------------------------------------

if [ -n "$OCTANE" ]; then
  add_program "octane" "php artisan octane:start --host=0.0.0.0 --port=8099"
else
  add_program_root "php-fpm" "/usr/sbin/php-fpm8.4 --nodaemonize"
  add_program_root "nginx" "/usr/sbin/nginx -g 'daemon off;'"
fi

# ---------------------------------------------------------------------------
# Queue processing: Horizon replaces generic worker
# ---------------------------------------------------------------------------

if [ -n "$HORIZON" ]; then
  add_program "horizon" "php artisan horizon"
elif [ -n "$NEEDS_QUEUE" ]; then
  add_program "queue-worker" "php artisan queue:work --tries=3 --sleep=3"
fi

# ---------------------------------------------------------------------------
# Scheduler
# ---------------------------------------------------------------------------

if [ -n "$NEEDS_SCHEDULER" ]; then
  add_program "scheduler" "php artisan schedule:work"
fi

# ---------------------------------------------------------------------------
# WebSockets
# ---------------------------------------------------------------------------

[ -n "$REVERB" ] && add_program "reverb" "php artisan reverb:start"
[ -n "$WS_OLD" ] && add_program "websockets" "php artisan websockets:serve"

# ---------------------------------------------------------------------------
# Monitoring daemons
# ---------------------------------------------------------------------------

[ -n "$NIGHTWATCH" ] && add_program "nightwatch" "php artisan nightwatch:agent"

if [ -n "$PULSE" ]; then
  add_program "pulse-check" "php artisan pulse:check"
  add_program "pulse-work" "php artisan pulse:work"
fi

echo "[discover] Done. Generated $CONF_FILE"
