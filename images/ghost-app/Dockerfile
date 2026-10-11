FROM ghost:6.69.0@sha256:55131b90d48c3cecae6c085f873b2067542ababd286b12d08474b2b34328e266 AS ghost-debian

FROM mysql:8.0.44@sha256:f37951fc3753a6a22d6c7bf6978c5e5fefcf6f31814d98c582524f98eae52b21 AS seed

COPY --from=ghost-debian /usr/local/bin/node /usr/local/bin/node
COPY --from=ghost-debian /var/lib/ghost /var/lib/ghost
COPY seed/ /seed/
RUN /seed/seed.sh

FROM scratch AS ghost-seed
COPY --from=seed /out/ /

FROM ghost:6.69.0-alpine@sha256:db4c56c196d6d5ed8ef9c0e80012792c16c51d4c23adb1683279506f525212b5 AS ghost-app

ENV url=http://ghost \
    database__client=mysql \
    database__connection__host=ghost-db \
    database__connection__user=ghost \
    database__connection__password=ghost \
    database__connection__database=ghost \
    security__staffDeviceVerification=false
COPY rootfs/ /
COPY --from=ghost-seed ghost.json /usr/share/rackcensus/ghost.json
RUN test "$GHOST_VERSION" = 6.69.0 && test "$(node -p 'require("/var/lib/ghost/current/package.json").version')" = 6.69.0
