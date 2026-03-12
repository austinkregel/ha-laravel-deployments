#!/usr/bin/env bash
#
# run.sh — HA-Laravel addon startup script.
# Sets up PHP/Node via ASDF, syncs the Laravel app from git,
# injects the HA auth overlay, installs dependencies (with caching),
# runs migrations, discovers services, and starts supervisord.
#
set -euo pipefail

APP_DIR="/data/app"
DATA_DIR="/data"
OVERLAY_DIR="/opt/ha-laravel/overlay"
OPTIONS_FILE="$DATA_DIR/options.json"
ENV_FILE="$APP_DIR/.env"

# ---------------------------------------------------------------------------
# Read addon options from HA
# ---------------------------------------------------------------------------

opt() {
  jq -r ".$1 // empty" "$OPTIONS_FILE" 2>/dev/null
}

opt_array() {
  jq -r ".$1[]? // empty" "$OPTIONS_FILE" 2>/dev/null
}

GIT_URL=$(opt git_url)
GIT_BRANCH=$(opt git_branch)
PHP_VERSION=$(opt php_version)
NODE_VERSION=$(opt node_version)
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
: "${PHP_VERSION:=8.4}"
: "${NODE_VERSION:=20}"
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
# ASDF runtime setup (persisted in /data/.asdf)
# ---------------------------------------------------------------------------

export ASDF_DIR="/opt/asdf"
export ASDF_DATA_DIR="/data/.asdf"
mkdir -p "$ASDF_DATA_DIR"

# shellcheck source=/dev/null
. "$ASDF_DIR/asdf.sh"

PHP_EXTENSIONS=$(opt_array php_extensions | sort | tr '\n' ',')
: "${PHP_EXTENSIONS:=mbstring,xml,curl,zip,bcmath,intl,gd,soap,gettext,sqlite3,mysql,pgsql,redis,opcache,fpm,}"

FINGERPRINT_INPUT="${PHP_VERSION}|${NODE_VERSION}|${PHP_EXTENSIONS}"
FINGERPRINT=$(echo -n "$FINGERPRINT_INPUT" | md5sum | awk '{print $1}')
FINGERPRINT_FILE="$ASDF_DATA_DIR/.fingerprint"

build_configure_options() {
  local opts="--enable-option-checking=fatal"
  local ext
  while IFS=',' read -ra exts; do
    for ext in "${exts[@]}"; do
      ext="$(echo "$ext" | xargs)"
      [ -z "$ext" ] && continue
      case "$ext" in
        fpm)       opts="$opts --enable-fpm --with-fpm-user=nginx --with-fpm-group=nginx" ;;
        mbstring)  opts="$opts --enable-mbstring" ;;
        bcmath)    opts="$opts --enable-bcmath" ;;
        intl)      opts="$opts --enable-intl" ;;
        soap)      opts="$opts --enable-soap" ;;
        opcache)   opts="$opts --enable-opcache" ;;
        gd)        opts="$opts --enable-gd --with-freetype --with-jpeg --with-webp" ;;
        xml)       opts="$opts --with-libxml" ;;
        curl)      opts="$opts --with-curl" ;;
        zip)       opts="$opts --with-zip" ;;
        gettext)   opts="$opts --with-gettext" ;;
        sodium)    opts="$opts --with-sodium" ;;
        readline)  opts="$opts --with-readline" ;;
        sqlite3)   opts="$opts --with-sqlite3 --with-pdo-sqlite" ;;
        mysql)     opts="$opts --with-mysqli --with-pdo-mysql" ;;
        pgsql)     opts="$opts --with-pgsql --with-pdo-pgsql" ;;
        openssl)   opts="$opts --with-openssl" ;;
        # PECL extensions are handled after compilation
        redis|imagick|xdebug|swoole) ;;
        *)         echo "[ha-laravel] WARNING: Unknown extension '$ext', skipping" ;;
      esac
    done
  done <<< "$PHP_EXTENSIONS"
  echo "$opts"
}

install_pecl_extensions() {
  local ext
  while IFS=',' read -ra exts; do
    for ext in "${exts[@]}"; do
      ext="$(echo "$ext" | xargs)"
      [ -z "$ext" ] && continue
      case "$ext" in
        redis|imagick|xdebug|swoole)
          echo "[ha-laravel] Installing PECL extension: $ext"
          pecl install "$ext" < /dev/null || echo "[ha-laravel] WARNING: pecl install $ext failed"
          local ini_dir
          ini_dir="$(php -r 'echo php_ini_scanned_dir();' 2>/dev/null || echo '')"
          if [ -n "$ini_dir" ]; then
            mkdir -p "$ini_dir"
            echo "extension=${ext}.so" > "$ini_dir/${ext}.ini"
          fi
          ;;
      esac
    done
  done <<< "$PHP_EXTENSIONS"
}

if [ -f "$FINGERPRINT_FILE" ] && [ "$(cat "$FINGERPRINT_FILE")" = "$FINGERPRINT" ]; then
  echo "[ha-laravel] ASDF fingerprint matches — using cached runtimes"
  asdf reshim php 2>/dev/null || true
  asdf reshim nodejs 2>/dev/null || true
else
  echo "[ha-laravel] Installing PHP ${PHP_VERSION} via ASDF (compiling from source)..."
  echo "[ha-laravel] This may take 10-40 minutes on first run."

  CONFIGURE_OPTS="$(build_configure_options)"
  export PHP_CONFIGURE_OPTIONS="$CONFIGURE_OPTS"
  echo "[ha-laravel] PHP_CONFIGURE_OPTIONS: $CONFIGURE_OPTS"

  asdf install php "$PHP_VERSION"
  asdf set --home php "$PHP_VERSION"

  install_pecl_extensions

  echo "[ha-laravel] Installing Node.js ${NODE_VERSION} via ASDF..."
  asdf install nodejs "$NODE_VERSION"
  asdf set --home nodejs "$NODE_VERSION"

  echo "$FINGERPRINT" > "$FINGERPRINT_FILE"
  echo "[ha-laravel] ASDF runtimes installed and cached"
fi

echo "[ha-laravel] PHP $(php -v | head -1)"
echo "[ha-laravel] Node $(node -v 2>/dev/null || echo 'not available')"

# ---------------------------------------------------------------------------
# PHP config
# ---------------------------------------------------------------------------

PHP_INI_TEMPLATE="/opt/ha-laravel/php.ini"
PHP_INI_DIR="$(php -r 'echo php_ini_scanned_dir();' 2>/dev/null || echo '')"

if [ -n "$PHP_INI_DIR" ] && [ -f "$PHP_INI_TEMPLATE" ]; then
  mkdir -p "$PHP_INI_DIR"
  sed "s/\${PHP_MEMORY_LIMIT}/$PHP_MEMORY_LIMIT/g" "$PHP_INI_TEMPLATE" \
    > "$PHP_INI_DIR/99-ha-laravel.ini"
fi

# ---------------------------------------------------------------------------
# Nginx config
# ---------------------------------------------------------------------------

mkdir -p /etc/nginx/http.d
cp /opt/ha-laravel/nginx.conf /etc/nginx/http.d/default.conf

# ---------------------------------------------------------------------------
# Sync app code from git
# ---------------------------------------------------------------------------

PREV_URL=""
[ -f "$DATA_DIR/.git_url" ] && PREV_URL=$(cat "$DATA_DIR/.git_url")

if [ ! -d "$APP_DIR/.git" ]; then
  echo "[ha-laravel] Cloning $GIT_URL (branch: $GIT_BRANCH)..."
  rm -rf "$APP_DIR"
  mkdir -p "$(dirname "$APP_DIR")"
  git clone --branch "$GIT_BRANCH" --depth 1 "$GIT_URL" "$APP_DIR"
  echo "$GIT_URL" > "$DATA_DIR/.git_url"
elif [ "$PREV_URL" != "$GIT_URL" ]; then
  echo "[ha-laravel] Git URL changed, re-cloning..."
  rm -rf "$APP_DIR"
  mkdir -p "$(dirname "$APP_DIR")"
  git clone --branch "$GIT_BRANCH" --depth 1 "$GIT_URL" "$APP_DIR"
  echo "$GIT_URL" > "$DATA_DIR/.git_url"
else
  echo "[ha-laravel] Syncing app to latest origin/$GIT_BRANCH..."
  cd "$APP_DIR"
  git fetch origin "$GIT_BRANCH" --depth 1
  git reset --hard "origin/$GIT_BRANCH"
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
# Install dependencies (skipped when lockfiles unchanged)
# ---------------------------------------------------------------------------

export COMPOSER_HOME="/data/.composer-cache"
export npm_config_cache="/data/.npm-cache"
mkdir -p "$COMPOSER_HOME" "$npm_config_cache"

HASH_FILE="$DATA_DIR/.lockfile-hashes"

current_composer_hash=""
current_npm_hash=""
[ -f "$APP_DIR/composer.lock" ] && current_composer_hash=$(md5sum "$APP_DIR/composer.lock" | awk '{print $1}')
[ -f "$APP_DIR/package-lock.json" ] && current_npm_hash=$(md5sum "$APP_DIR/package-lock.json" | awk '{print $1}')

prev_composer_hash=""
prev_npm_hash=""
if [ -f "$HASH_FILE" ]; then
  prev_composer_hash=$(sed -n '1p' "$HASH_FILE")
  prev_npm_hash=$(sed -n '2p' "$HASH_FILE")
fi

if [ "$current_composer_hash" != "$prev_composer_hash" ]; then
  echo "[ha-laravel] composer.lock changed — installing dependencies..."
  composer install --no-dev --no-interaction --optimize-autoloader --working-dir="$APP_DIR"
else
  echo "[ha-laravel] composer.lock unchanged — skipping composer install"
fi

if [ -f "$APP_DIR/package.json" ]; then
  if [ "$current_npm_hash" != "$prev_npm_hash" ]; then
    echo "[ha-laravel] package-lock.json changed — installing npm dependencies..."
    cd "$APP_DIR"
    npm ci --no-audit --no-fund 2>/dev/null || npm install --no-audit --no-fund
    npm run build 2>/dev/null || echo "[ha-laravel] WARNING: npm run build failed (may not have a build script)"
  else
    echo "[ha-laravel] package-lock.json unchanged — skipping npm install"
  fi
fi

printf '%s\n%s\n' "$current_composer_hash" "$current_npm_hash" > "$HASH_FILE"

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

chown -R nginx:nginx "$APP_DIR"
chmod -R 755 "$APP_DIR/storage" "$APP_DIR/bootstrap/cache"

if [ "$DB_CONNECTION" = "sqlite" ] && [ -f "$DB_DATABASE" ]; then
  chown nginx:nginx "$DB_DATABASE"
  chmod 664 "$DB_DATABASE"
fi

# ---------------------------------------------------------------------------
# Cron (for schedule:run fallback if scheduler is not via supervisor)
# ---------------------------------------------------------------------------

echo "* * * * * cd $APP_DIR && php artisan schedule:run >> /dev/null 2>&1" | crontab -u nginx -

# ---------------------------------------------------------------------------
# Start supervisord
# ---------------------------------------------------------------------------

echo "[ha-laravel] Starting services..."
mkdir -p /var/log/supervisor
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
