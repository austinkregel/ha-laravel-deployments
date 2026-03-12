ARG BUILD_FROM
FROM ${BUILD_FROM}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV LANG=C.UTF-8

# Runtime packages + PHP/Node build dependencies
# All kept in the final image so ASDF can recompile on version change
RUN apk add --no-cache \
    bash \
    nginx \
    supervisor \
    git \
    jq \
    curl \
    wget \
    openssh-client \
    openssl \
    zip \
    unzip \
    patch \
    # PHP build dependencies
    autoconf \
    automake \
    bison \
    build-base \
    re2c \
    curl-dev \
    freetype-dev \
    gettext-dev \
    icu-dev \
    libjpeg-turbo-dev \
    libpng-dev \
    libsodium-dev \
    libxml2-dev \
    libzip-dev \
    oniguruma-dev \
    openssl-dev \
    postgresql-dev \
    sqlite-dev \
    readline-dev \
    libwebp-dev \
    linux-headers \
    # Node.js build fallback (needed if no musl binary)
    python3

# ASDF version manager
ENV ASDF_DIR=/opt/asdf
RUN git clone --depth 1 https://github.com/asdf-vm/asdf.git ${ASDF_DIR} --branch v0.16.7 \
    && echo ". ${ASDF_DIR}/asdf.sh" >> /root/.bashrc

ENV PATH="${ASDF_DIR}/shims:${ASDF_DIR}/bin:${PATH}"

# Pre-install ASDF plugins (actual runtimes installed at boot into /data/.asdf)
RUN asdf plugin add php https://github.com/asdf-community/asdf-php.git \
    && asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git

# Composer (standalone PHAR, no PHP dependency at build time)
RUN curl -sS https://getcomposer.org/installer -o /tmp/composer-setup.php \
    && EXPECTED_CHECKSUM="$(curl -sS https://composer.github.io/installer.sig)" \
    && ACTUAL_CHECKSUM="$(sha384sum /tmp/composer-setup.php | awk '{print $1}')" \
    && if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then echo 'Composer installer corrupt'; exit 1; fi \
    && php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer 2>/dev/null \
    || (echo "Composer PHAR installed without PHP verification" \
        && curl -sS https://getcomposer.org/download/latest-stable/composer.phar -o /usr/local/bin/composer) \
    && chmod +x /usr/local/bin/composer \
    && rm -f /tmp/composer-setup.php

# Remove default nginx site
RUN rm -f /etc/nginx/http.d/default.conf

# Copy addon scripts and configs
COPY run.sh /opt/ha-laravel/run.sh
COPY discover.sh /opt/ha-laravel/discover.sh
COPY nginx.conf /opt/ha-laravel/nginx.conf
COPY php.ini /opt/ha-laravel/php.ini
COPY php-fpm.conf /opt/ha-laravel/php-fpm.conf
COPY supervisord.conf /etc/supervisor/supervisord.conf

RUN chmod +x /opt/ha-laravel/run.sh /opt/ha-laravel/discover.sh

# Copy the overlay (middleware, provider, config) to a staging area
COPY overlay/ /opt/ha-laravel/overlay/

EXPOSE 8099

ARG BUILD_ARCH=amd64
ARG BUILD_DATE
ARG BUILD_REF
ARG BUILD_VERSION
LABEL \
  io.hass.name="Haravel Deploy" \
  io.hass.description="Laravel app on Home Assistant" \
  io.hass.arch="${BUILD_ARCH}" \
  io.hass.type="addon" \
  io.hass.version="${BUILD_VERSION}"

CMD ["/opt/ha-laravel/run.sh"]
