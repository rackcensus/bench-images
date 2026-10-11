FROM discourse/base:2.0.20260915-0028@sha256:5028d077b061225507e7093fda1ff5bdc64d483b5c0397776f9a52c50008cd9b AS bootstrap

ADD https://github.com/discourse/discourse_docker.git#ac99052ff83bb79df1ad99684aa40e879aff2b27 /var/discourse
COPY app.yml /var/discourse/containers/app.yml
COPY bootstrap /usr/local/bin/rc-discourse-bootstrap
COPY rootfs/ /
RUN set -eux; \
    rc-discourse-bootstrap /var/discourse /var/discourse/containers/app.yml; \
    rm -rf /var/discourse /usr/local/bin/rc-discourse-bootstrap; \
    test "$(git -c safe.directory=* -C /var/www/discourse rev-parse HEAD)" = 7d3d93e083b41f478616fa6447b884a50911187e; \
    test "$(git -c safe.directory=* -C /var/www/discourse/plugins/docker_manager rev-parse HEAD)" = 0d26ddaac1f5073d989f689c6b928cbb53d93c0d; \
    grep -q '^shared_buffers = 128MB' /etc/postgresql/18/main/postgresql.conf

FROM bootstrap AS seed
COPY seed/ /seed/
RUN /seed/seed.sh

FROM scratch AS discourse-seed
COPY --from=seed /out/ /

FROM bootstrap AS discourse
RUN --mount=type=bind,from=discourse-seed,target=/seed set -eux; \
    ruby -rjson -rdigest -e 'm = JSON.parse(File.read(ARGV[0])); abort "the seed dump does not match its manifest" unless Digest::SHA256.file(ARGV[1]).hexdigest == m["dump_sha256"]' \
      /seed/discourse.json /seed/discourse.dump; \
    rc-discourse-services start; \
    su postgres -c 'dropdb discourse'; \
    su postgres -c 'createdb --template=template0 --owner=discourse --encoding=UTF8 discourse'; \
    su postgres -c 'pg_restore --exit-on-error --dbname=discourse /seed/discourse.dump'; \
    su postgres -c "psql -tA -d discourse -c \"SELECT count(*) FROM users WHERE id > 0\"" | grep -qx 101; \
    rc-discourse-services stop; \
    rm -f /shared/postgres_data/postmaster.pid /tmp/rc-postgres.log; \
    install -D -m 0644 /seed/discourse.json /usr/share/rackcensus/discourse.json

CMD ["/usr/local/bin/rc-discourse-start"]
