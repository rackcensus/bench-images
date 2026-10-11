FROM postgres:18.6@sha256:fc973eb97c9fd04bfa1840e0f510719a584ccb3be8debfe6a4144637a9dfe8cf

ENV POSTGRES_DB=app_db \
    POSTGRES_USER=app_user \
    POSTGRES_PASSWORD=changeme

COPY --from=wagtail-seed seed.sql.gz /docker-entrypoint-initdb.d/10-wagtail.sql.gz
COPY --from=wagtail-seed wagtail.json /usr/share/rackcensus/wagtail.json
