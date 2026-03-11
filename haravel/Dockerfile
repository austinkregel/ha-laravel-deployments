FROM ubuntu:24.04

WORKDIR /var/www/html

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# System packages
RUN apt-get update && apt-get upgrade -y && apt-get install -y \
    software-properties-common \
    curl \
    zip \
    unzip \
    git \
    nginx \
    supervisor \
    cron \
    gnupg \
    ca-certificates \
    jq \
    openssh-client \
    && add-apt-repository ppa:ondrej/php -y \
    && apt-get update

# PHP 8.4 + extensions for all common Laravel needs
RUN apt-get install -y \
    php8.4 \
    php8.4-fpm \
    php8.4-mbstring \
    php8.4-xml \
    php8.4-curl \
    php8.4-zip \
    php8.4-bcmath \
    php8.4-intl \
    php8.4-gd \
    php8.4-soap \
    php8.4-gettext \
    php8.4-sqlite3 \
    php8.4-mysql \
    php8.4-pgsql \
    php8.4-redis \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Composer
RUN curl -sS https://getcomposer.org/installer | php -- \
    --install-dir=/usr/local/bin --filename=composer

# Node.js 20 + npm
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Remove default nginx site
RUN rm -f /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

# Copy addon scripts and configs
COPY run.sh /opt/ha-laravel/run.sh
COPY discover.sh /opt/ha-laravel/discover.sh
COPY nginx.conf /opt/ha-laravel/nginx.conf
COPY php.ini /opt/ha-laravel/php.ini
COPY supervisord.conf /etc/supervisor/supervisord.conf

RUN chmod +x /opt/ha-laravel/run.sh /opt/ha-laravel/discover.sh

# Copy the overlay (middleware, provider, config) to a staging area
COPY overlay/ /opt/ha-laravel/overlay/

EXPOSE 80

CMD ["/opt/ha-laravel/run.sh"]
