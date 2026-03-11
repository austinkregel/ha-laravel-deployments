#!/usr/bin/env bash
#
# run.sh — HA-Laravel addon startup script.
# Clones a Laravel app at runtime, injects the HA auth overlay,
# installs dependencies, runs migrations, discovers services,
# and starts supervisord.
#
set -euo pipefail

APP_DIR="/var/www/html"
DATA_DIR="/data"
OVERLAY_DIR="/opt/ha-laravel/overlay"
OPTIONS_FILE="$DATA_DIR/options.json"
INIT_FLAG="$DATA_DIR/.initialized"
ENV_FILE="$APP_DIR/.env"

# ---------------------------------------------------------------------------
# Read addon options from HA
# ---------------------------------------------------------------------------

opt() {
  jq -r ".$1 // empty" "$OPTIONS_FILE" 2>/dev/null
}

GIT_URL=$(opt git_url)
GIT_BRANCH=$(opt git_branch)
DB_CONNECTION=$(opt db_connection)
DB_HOST=$(opt db_host)
DB_PORT=$(opt db_port)
DB_DATABASE=$(opt db_database)
DB_USERNAME=$(opt db_username)
DB_PASSWORD=$(opt db_password)
REDIS_HOST=$(opt redis_host)
REDIS_PORT=$(opt redis_port)
REDIS_DB=$(opt redis_db)
REDIS_PASSWORD=$(opt redis_password)
PHP_MEMORY_LIMIT=$(opt php_memory_limit)

: "${GIT_BRANCH:=main}"
: "${DB_CONNECTION:=sqlite}"
: "${DB_PORT:=3306}"
: "${REDIS_PORT:=6379}"
: "${REDIS_DB:=0}"
: "${PHP_MEMORY_LIMIT:=256M}"

if [ -z "$GIT_URL" ]; then
  echo "[ha-laravel] ERROR: git_url is not configured. Set it in the addon options."
  exit 1
fi

# ---------------------------------------------------------------------------
# PHP config
# ---------------------------------------------------------------------------

PHP_INI="/opt/ha-laravel/php.ini"
if [ -f "$PHP_INI" ]; then
  sed "s/\${PHP_MEMORY_LIMIT}/$PHP_MEMORY_LIMIT/g" "$PHP_INI" \
    > /etc/php/8.4/cli/conf.d/99-ha-laravel.ini
  sed "s/\${PHP_MEMORY_LIMIT}/$PHP_MEMORY_LIMIT/g" "$PHP_INI" \
    > /etc/php/8.4/fpm/conf.d/99-ha-laravel.ini
fi

# ---------------------------------------------------------------------------
# Nginx config
# ---------------------------------------------------------------------------

cp /opt/ha-laravel/nginx.conf /etc/nginx/sites-available/default
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

# ---------------------------------------------------------------------------
# Clone or update the Laravel app
# ---------------------------------------------------------------------------

clone_app() {
  echo "[ha-laravel] Cloning $GIT_URL (branch: $GIT_BRANCH)..."
  rm -rf "$APP_DIR"
  mkdir -p "$(dirname "$APP_DIR")"
  git clone --branch "$GIT_BRANCH" --depth 1 "$GIT_URL" "$APP_DIR"
  echo "$GIT_URL" > "$DATA_DIR/.git_url"
}

PREV_URL=""
[ -f "$DATA_DIR/.git_url" ] && PREV_URL=$(cat "$DATA_DIR/.git_url")

if [ ! -f "$INIT_FLAG" ]; then
  clone_app
elif [ "$PREV_URL" != "$GIT_URL" ]; then
  echo "[ha-laravel] Git URL changed, re-cloning..."
  clone_app
else
  echo "[ha-laravel] Updating existing app..."
  cd "$APP_DIR"
  git pull origin "$GIT_BRANCH" || echo "[ha-laravel] WARNING: git pull failed, continuing with existing code"
fi

cd "$APP_DIR"

# ---------------------------------------------------------------------------
# Inject HA overlay files
# ---------------------------------------------------------------------------

echo "[ha-laravel] Injecting HA overlay..."
cp -r "$OVERLAY_DIR/app" "$APP_DIR/"
cp -r "$OVERLAY_DIR/config" "$APP_DIR/"

# ---------------------------------------------------------------------------
# Register HomeAssistantServiceProvider in the Laravel app
# ---------------------------------------------------------------------------

register_provider() {
  local PROVIDER="App\\\\Providers\\\\HomeAssistantServiceProvider::class"

  # Laravel 11+: bootstrap/providers.php
  if [ -f "$APP_DIR/bootstrap/providers.php" ]; then
    if ! grep -q "HomeAssistantServiceProvider" "$APP_DIR/bootstrap/providers.php"; then
      echo "[ha-laravel] Registering provider in bootstrap/providers.php"
      sed -i "s|return \[|return [\n        ${PROVIDER},|" "$APP_DIR/bootstrap/providers.php"
    fi
    return
  fi

  # Laravel 8-10: config/app.php
  if [ -f "$APP_DIR/config/app.php" ]; then
    if ! grep -q "HomeAssistantServiceProvider" "$APP_DIR/config/app.php"; then
      echo "[ha-laravel] Registering provider in config/app.php"
      sed -i "/App\\\\Providers\\\\RouteServiceProvider::class/a\\        ${PROVIDER}," "$APP_DIR/config/app.php" \
        || sed -i "/'providers'.*=>/,/\]/s|\];|        ${PROVIDER},\n    ];|" "$APP_DIR/config/app.php"
    fi
    return
  fi

  echo "[ha-laravel] WARNING: Could not find providers registration file"
}

register_provider

# ---------------------------------------------------------------------------
# Generate .env
# ---------------------------------------------------------------------------

echo "[ha-laravel] Writing .env..."

APP_KEY=""
if [ -f "$DATA_DIR/.app_key" ]; then
  APP_KEY=$(cat "$DATA_DIR/.app_key")
fi

if [ -z "$APP_KEY" ]; then
  APP_KEY="base64:$(openssl rand -base64 32)"
  echo "$APP_KEY" > "$DATA_DIR/.app_key"
  echo "[ha-laravel] Generated new APP_KEY"
fi

# For SQLite, create the database file in persistent storage
if [ "$DB_CONNECTION" = "sqlite" ]; then
  DB_DATABASE="$DATA_DIR/database.sqlite"
  [ -f "$DB_DATABASE" ] || touch "$DB_DATABASE"
fi

cat > "$ENV_FILE" <<ENVEOF
APP_NAME=HA-Laravel
APP_ENV=production
APP_KEY=${APP_KEY}
APP_DEBUG=false
APP_URL=http://localhost

LOG_CHANNEL=stderr

DB_CONNECTION=${DB_CONNECTION}
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_DATABASE=${DB_DATABASE}
DB_USERNAME=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}

REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_DB=${REDIS_DB}

CACHE_STORE=file
SESSION_DRIVER=file
QUEUE_CONNECTION=sync

HA_VERIFY_SUPERVISOR=true
ENVEOF

# If Redis is configured, use it for cache/session/queue
if [ -n "$REDIS_HOST" ]; then
  sed -i 's/CACHE_STORE=file/CACHE_STORE=redis/' "$ENV_FILE"
  sed -i 's/SESSION_DRIVER=file/SESSION_DRIVER=redis/' "$ENV_FILE"
  sed -i 's/QUEUE_CONNECTION=sync/QUEUE_CONNECTION=redis/' "$ENV_FILE"
fi

# Merge any app-specific .env.example values the user may need
if [ -f "$APP_DIR/.env.example" ]; then
  while IFS='=' read -r key _; do
    key="$(echo "$key" | xargs)"
    [[ -z "$key" || "$key" == \#* ]] && continue
    if ! grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
      grep "^${key}=" "$APP_DIR/.env.example" >> "$ENV_FILE" || true
    fi
  done < "$APP_DIR/.env.example"
fi

# ---------------------------------------------------------------------------
# Install dependencies
# ---------------------------------------------------------------------------

echo "[ha-laravel] Installing composer dependencies..."
composer install --no-dev --no-interaction --optimize-autoloader --working-dir="$APP_DIR"

if [ -f "$APP_DIR/package.json" ]; then
  echo "[ha-laravel] Installing npm dependencies and building assets..."
  cd "$APP_DIR"
  npm ci --no-audit --no-fund 2>/dev/null || npm install --no-audit --no-fund
  npm run build 2>/dev/null || echo "[ha-laravel] WARNING: npm run build failed (may not have a build script)"
fi

cd "$APP_DIR"

# ---------------------------------------------------------------------------
# Run service discovery
# ---------------------------------------------------------------------------

echo "[ha-laravel] Running service discovery..."
/opt/ha-laravel/discover.sh "$APP_DIR"

# ---------------------------------------------------------------------------
# One-time setup commands
# ---------------------------------------------------------------------------

CASHIER=$(jq -r '.require["laravel/cashier-stripe"] // .require["laravel/cashier"] // empty' "$APP_DIR/composer.json" 2>/dev/null)
if [ -n "$CASHIER" ] && [ ! -f "$DATA_DIR/.cashier_webhook_registered" ]; then
  echo "[ha-laravel] Registering Cashier webhook..."
  php artisan cashier:webhook 2>/dev/null && touch "$DATA_DIR/.cashier_webhook_registered" \
    || echo "[ha-laravel] WARNING: cashier:webhook failed (APP_URL may need to be set correctly)"
fi

# ---------------------------------------------------------------------------
# Migrations
# ---------------------------------------------------------------------------

echo "[ha-laravel] Running migrations..."
php artisan migrate --force

# ---------------------------------------------------------------------------
# Optimize
# ---------------------------------------------------------------------------

php artisan optimize:clear 2>/dev/null || true
php artisan optimize 2>/dev/null || true

# ---------------------------------------------------------------------------
# Permissions
# ---------------------------------------------------------------------------

chown -R www-data:www-data "$APP_DIR"
chmod -R 755 "$APP_DIR/storage" "$APP_DIR/bootstrap/cache"

if [ "$DB_CONNECTION" = "sqlite" ] && [ -f "$DB_DATABASE" ]; then
  chown www-data:www-data "$DB_DATABASE"
  chmod 664 "$DB_DATABASE"
fi

touch "$INIT_FLAG"

# ---------------------------------------------------------------------------
# Cron (for schedule:run fallback if scheduler is not via supervisor)
# ---------------------------------------------------------------------------

echo "* * * * * cd $APP_DIR && php artisan schedule:run >> /dev/null 2>&1" | crontab -u www-data -

# ---------------------------------------------------------------------------
# Start supervisord
# ---------------------------------------------------------------------------

echo "[ha-laravel] Starting services..."
mkdir -p /var/log/supervisor
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
