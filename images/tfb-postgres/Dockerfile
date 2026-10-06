FROM postgres:18.6@sha256:fc973eb97c9fd04bfa1840e0f510719a584ccb3be8debfe6a4144637a9dfe8cf

ENV POSTGRES_DB=hello_world \
    POSTGRES_PASSWORD=benchmarkdbpass \
    POSTGRES_USER=benchmarkdbuser

COPY config.sh create-postgres.sql postgresql.conf /docker-entrypoint-initdb.d/
COPY LICENSE.tfb /usr/share/doc/tfb-postgres/LICENSE
