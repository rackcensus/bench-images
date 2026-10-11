FROM mysql:8.0.44@sha256:f37951fc3753a6a22d6c7bf6978c5e5fefcf6f31814d98c582524f98eae52b21

ENV MYSQL_ROOT_PASSWORD=ghost \
    MYSQL_USER=ghost \
    MYSQL_PASSWORD=ghost \
    MYSQL_DATABASE=ghost

COPY --from=ghost-seed seed.sql.gz /docker-entrypoint-initdb.d/10-ghost.sql.gz
COPY --from=ghost-seed ghost.json /usr/share/rackcensus/ghost.json
