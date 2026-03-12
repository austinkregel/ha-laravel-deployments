# HA-Laravel

Run any Laravel 8+ application as a Home Assistant addon with automatic
Home Assistant authentication, service discovery, and multi-instance support.

## Features

- **Any Laravel app** -- provide a git URL and the addon clones, installs, and
  serves it automatically.
- **Configurable PHP & Node.js** -- choose your PHP version (8.1-8.4) and
  Node.js version (18, 20, 22) via addon options. Runtimes are compiled via
  ASDF on first boot and cached for fast restarts.
- **Selectable PHP extensions** -- pick exactly which extensions to compile
  (mbstring, gd, redis, pgsql, etc.) from the addon configuration.
- **Home Assistant SSO** -- users are authenticated via HA's ingress proxy.
  The addon reads `X-Remote-User-*` headers, creates a matching Laravel user,
  and calls `Auth::login()`. No separate login page needed.
- **Service auto-discovery** -- `composer.json` and the app directory structure
  are scanned at startup to determine which background services are needed
  (Horizon, Reverb, Pulse, Nightwatch, queue workers, scheduler, etc.).
  Only the services the app actually uses are started.
- **All database drivers** -- SQLite, MySQL/MariaDB, and PostgreSQL are all
  supported. Point the addon at your HA database addon or use the built-in
  SQLite default.
- **Multiple instances** -- run as many Laravel apps as you want by generating
  a new addon folder for each one with a unique slug.
- **Smart code updates** -- on restart, `git fetch && git reset --hard` syncs
  your app to the latest remote commit. Dependencies are only reinstalled when
  lockfiles change.
- **Procfile override** -- drop a `Procfile` in your Laravel app root to define
  your own process layout and skip auto-discovery entirely.

## Quick Start

### 1. Generate an addon instance

```bash
./generate.sh --name "My App" --slug my-app
```

This creates a `my-app/` directory containing a complete, self-contained
Home Assistant addon.

### 2. Add the repository to Home Assistant

In Home Assistant, go to **Settings -> Add-ons -> Add-on Store -> ... ->
Repositories** and add the URL of this git repository.

### 3. Install and configure

Install the **My App** addon from the store. In its **Configuration** tab, set:

| Option | Description |
|---|---|
| `git_url` | Git clone URL of your Laravel project |
| `git_branch` | Branch to clone (default: `main`) |
| `php_version` | PHP version to install via ASDF (default: `8.4`) |
| `node_version` | Node.js version to install via ASDF (default: `20`) |
| `php_extensions` | List of PHP extensions to compile (see defaults below) |
| `db_connection` | `sqlite`, `mysql`, `mariadb`, or `pgsql` |
| `db_host` | Database host (ignored for SQLite) |
| `db_port` | Database port (default: `3306`) |
| `db_database` | Database name or path |
| `db_username` | Database user |
| `db_password` | Database password |
| `redis_host` | Redis addon hostname (leave empty to disable) |
| `redis_port` | Redis port (default: `6379`) |
| `redis_db` | Redis database number 0-15 (default: `0`) |
| `redis_password` | Redis password (leave empty if none) |
| `php_memory_limit` | PHP memory limit (default: `256M`) |

#### Default PHP extensions

```
mbstring, xml, curl, zip, bcmath, intl, gd, soap, gettext,
sqlite3, mysql, pgsql, redis, opcache, fpm
```

Extensions are categorized automatically:
- **Compile-time** (built into PHP): mbstring, xml, curl, zip, bcmath, intl, gd,
  soap, gettext, sqlite3, mysql, pgsql, opcache, sodium, fpm, readline, openssl
- **PECL** (installed after compilation): redis, imagick, xdebug, swoole

### 4. Start

Start the addon. On first boot it will compile PHP and Node.js via ASDF
(10-40 minutes depending on hardware), clone the repo, install dependencies,
run migrations, and start serving the app behind HA ingress. Subsequent
restarts are fast -- runtimes are cached and dependencies are only reinstalled
when lockfiles change.

## How Authentication Works

```
Browser -> HA Supervisor (ingress proxy) -> Addon container
               |
               |-- Validates HA session
               |-- Injects X-Remote-User-ID header
               |-- Injects X-Remote-User-Name header
               +-- Injects X-Remote-User-Display-Name header
                                          |
                                          v
                              HomeAssistantAuth middleware
                                          |
                                          |-- Verifies SUPERVISOR_TOKEN
                                          |-- User::firstOrCreate(...)
                                          +-- Auth::login($user)
```

The addon only handles **identity**. Each Laravel app manages its own
roles, permissions, and authorization through its own UI and models.

## Code Updates

App code lives in `/data/app/` and is synced with the remote on every restart:

```
git fetch origin <branch> --depth 1
git reset --hard origin/<branch>
```

This guarantees the running code always matches the remote. Local edits are
discarded. To update your app, push to your repo and restart the addon.

Dependencies (`composer install`, `npm ci`) are only re-run when
`composer.lock` or `package-lock.json` change (hash comparison). Even when
they do change, download caches in `/data/.composer-cache/` and
`/data/.npm-cache/` keep reinstalls fast.

## What Persists Across Restarts

| Path | Contents |
|---|---|
| `/data/.asdf/` | Compiled PHP and Node.js runtimes |
| `/data/app/` | Cloned Laravel application code |
| `/data/.app_key` | Laravel APP_KEY |
| `/data/database.sqlite` | SQLite database (if used) |
| `/data/.composer-cache/` | Composer download cache |
| `/data/.npm-cache/` | npm download cache |
| `/data/.lockfile-hashes` | Dependency lockfile hashes |

## Service Auto-Discovery

At startup, `discover.sh` scans your Laravel app and generates Supervisor
program configurations dynamically:

| Detected | Supervisor program |
|---|---|
| `laravel/octane` | `php artisan octane:start` (replaces php-fpm + nginx) |
| `laravel/horizon` | `php artisan horizon` (replaces generic queue worker) |
| `laravel/reverb` | `php artisan reverb:start` |
| `beyondcode/laravel-websockets` | `php artisan websockets:serve` |
| `laravel/nightwatch` | `php artisan nightwatch:agent` |
| `laravel/pulse` | `php artisan pulse:check` + `php artisan pulse:work` |
| `app/Jobs/` or `app/Listeners/` present | `php artisan queue:work` |
| `app/Console/Kernel.php` or `routes/console.php` | `php artisan schedule:work` |
| `spatie/laravel-backup`, `spatie/laravel-health`, etc. | Forces scheduler on |
| `spatie/laravel-media-library`, `laravel/scout`, etc. | Forces queue worker on |
| `Procfile` in app root | Uses developer-defined processes verbatim |

## Running Multiple Apps

Each call to `generate.sh` creates an independent addon with its own slug:

```bash
./generate.sh --name "VitoDeploy" --slug vito
./generate.sh --name "My CRM" --slug my-crm
./generate.sh --name "Invoice App" --slug invoices
```

Each addon appears separately in the HA Add-on Store and can be configured,
started, and stopped independently. Apps can share a Redis instance by using
different `redis_db` numbers (0-15).

## Repository Structure

```
├── repository.json          # HA addon repository metadata
├── generate.sh              # Creates new addon instances
├── template/
│   ├── config.json.tpl      # Addon config template
│   ├── build.json           # HA base image mapping (Alpine)
│   ├── Dockerfile           # Alpine + ASDF runtime image
│   ├── run.sh               # Startup script (ASDF + git sync + Laravel)
│   ├── discover.sh          # Service auto-discovery
│   ├── nginx.conf           # Nginx config with HA header passthrough
│   ├── php.ini              # PHP configuration overrides
│   ├── php-fpm.conf         # PHP-FPM pool configuration
│   ├── supervisord.conf     # Base Supervisor config
│   └── overlay/
│       ├── app/Http/Middleware/
│       │   ├── HomeAssistantAuth.php
│       │   └── TrustIngress.php
│       ├── app/Providers/
│       │   └── HomeAssistantServiceProvider.php
│       └── config/
│           └── homeassistant.php
```

## Requirements

- Home Assistant OS or Supervised installation
- For MySQL/MariaDB/PostgreSQL: a corresponding database addon
- For queue/cache/session via Redis: a Redis addon

## License

[MIT](LICENSE)
