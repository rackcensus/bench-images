FROM php:8.4.26-fpm-trixie@sha256:14ae2e2ff06c5b60196e017cfdf4f21858f28cca794571d002171520272864f8 AS php

ARG DEBIAN_FRONTEND=noninteractive
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends nginx tini; \
    savedAptMark="$(apt-mark showmanual)"; \
    apt-get install -y --no-install-recommends libfreetype-dev libicu-dev libjpeg62-turbo-dev libpng-dev libwebp-dev libzip-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp; \
    docker-php-ext-install -j"$(nproc)" bcmath exif gd intl mysqli zip; \
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    extdir="$(php -r 'echo ini_get("extension_dir");')"; \
    ldd "$extdir"/*.so \
      | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
      | sort -u | xargs -r dpkg-query --search | cut -d: -f1 | sort -u | xargs -r apt-mark manual; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/* /etc/nginx/sites-enabled/* /etc/nginx/conf.d/* /usr/local/etc/php-fpm.d/*; \
    cp /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini; \
    for ext in bcmath exif gd intl mysqli zip "Zend OPcache"; do php -m | grep -qx "$ext"; done

COPY rootfs/ /

FROM php AS wordpress

ADD --checksum=sha256:c0c666689d66b870d8825500bb8e402ed04de52602c61a6f516c6236b8c9ac67 https://downloads.wordpress.org/release/wordpress-7.1.2.tar.gz /tmp/wordpress.tar.gz
ADD --checksum=sha256:9de9350a1cf5671b9960afb3151f40f7980e223217a441bf2ea5921b5fce8e9e https://downloads.wordpress.org/plugin/woocommerce.11.1.2.zip /tmp/woocommerce.zip
RUN set -eux; \
    rm -rf /var/www/html; \
    tar -xzf /tmp/wordpress.tar.gz -C /var/www; \
    mv /var/www/wordpress /var/www/html; \
    cd /var/www/html; \
    rm -rf wp-config-sample.php wp-content/plugins/akismet wp-content/plugins/hello.php wp-content/themes/twentytwentythree wp-content/themes/twentytwentyfour; \
    php -r '$z = new ZipArchive(); if ($z->open($argv[1]) !== true || !$z->extractTo($argv[2])) { exit(1); }' /tmp/woocommerce.zip wp-content/plugins; \
    rm /tmp/wordpress.tar.gz /tmp/woocommerce.zip; \
    php -r 'echo "<?php\n"; foreach (["AUTH_KEY", "SECURE_AUTH_KEY", "LOGGED_IN_KEY", "NONCE_KEY", "AUTH_SALT", "SECURE_AUTH_SALT", "LOGGED_IN_SALT", "NONCE_SALT"] as $k) { printf("define(%s, %s);\n", var_export($k, true), var_export(bin2hex(random_bytes(32)), true)); }' > wp-salts.php; \
    mkdir -p wp-content/uploads; \
    chown www-data:www-data wp-content/uploads; \
    grep -q "Version: 7.1.2\|wp_version = '7.1.2'" wp-includes/version.php; \
    grep -q "Version: 11.1.2" wp-content/plugins/woocommerce/woocommerce.php; \
    grep -q "Version: 1.5" wp-content/themes/twentytwentyfive/style.css

COPY wp-config.php /var/www/html/wp-config.php

FROM wordpress AS seed

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends mariadb-server \
 && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:ce34ddd838f7351d6759068d09793f26755463b4a4610a5a5c0a97b68220d85c https://github.com/wp-cli/wp-cli/releases/download/v2.12.0/wp-cli-2.12.0.phar /usr/local/bin/wp-cli.phar
ADD --checksum=sha256:85cfad65e24eb3b25ed536f52ce52c3971bd42a852d6f2c6a5bea8c5c429c323 https://downloads.wordpress.org/plugin/wordpress-importer.0.9.6.zip /seed/wordpress-importer.zip
COPY seed/ /seed/
RUN php /seed/fetch-images.php /var/www/html/wp-content/plugins/woocommerce/sample-data/sample_products.xml /seed/images
RUN /seed/seed.sh

FROM scratch AS woo-seed
COPY --from=seed /out/ /

FROM wordpress AS woo-app

COPY --from=woo-seed --chown=www-data:www-data uploads/ /var/www/html/wp-content/uploads/
COPY --from=woo-seed woocommerce.json /usr/share/rackcensus/woocommerce.json
EXPOSE 80
ENTRYPOINT ["tini", "-s", "-g", "--"]
CMD ["woo-start"]
