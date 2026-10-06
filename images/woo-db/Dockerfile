FROM mariadb:12.3.3@sha256:2bdff1534a7e569fecaf4b10b66ad0d410806e382d9db29ba305448addda97c4

ENV MARIADB_DATABASE=woocommerce \
    MARIADB_USER=woo \
    MARIADB_PASSWORD=woo \
    MARIADB_ROOT_PASSWORD=woo \
    MARIADB_ROOT_HOST=localhost

COPY --from=woo-seed seed.sql.gz /docker-entrypoint-initdb.d/10-woocommerce.sql.gz
COPY --from=woo-seed woocommerce.json /usr/share/rackcensus/woocommerce.json
