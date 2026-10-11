FROM ghcr.io/astral-sh/uv:0.11.16@sha256:440fd6477af86a2f1b38080c539f1672cd22acb1b1a47e321dba5158ab08864d AS uv

FROM python:3.12.15-slim-trixie@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1 AS app

COPY --from=uv /uv /uvx /bin/
ARG DEBIAN_FRONTEND=noninteractive
RUN set -ex \
    && RUN_DEPS=" \
        libexpat1 \
        libjpeg62-turbo \
        libpcre2-posix3 \
        libpq5 \
        shared-mime-info \
        postgresql-client \
        procps \
        zlib1g \
    " \
    && seq 1 8 | xargs -I{} mkdir -p /usr/share/man/man{} \
    && apt-get update && apt-get install -y --no-install-recommends $RUN_DEPS \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.lock /requirements.lock
ENV VIRTUAL_ENV=/venv PATH=/venv/bin:$PATH PYTHONPATH=/code/
RUN set -ex \
    && BUILD_DEPS=" \
        build-essential \
        libexpat1-dev \
        libjpeg62-turbo-dev \
        libpcre2-dev \
        libpq-dev \
        zlib1g-dev \
    " \
    && apt-get update && apt-get install -y --no-install-recommends $BUILD_DEPS \
    && uv venv ${VIRTUAL_ENV} \
    && uv pip install --no-cache --require-hashes -r /requirements.lock \
    && apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false $BUILD_DEPS \
    && rm -rf /var/lib/apt/lists/*

ADD https://github.com/wagtail/bakerydemo.git#c8f8255593c0efcfab5fef2fb19d60895227748a /code/
WORKDIR /code/
ENV PORT=8000 \
    DJANGO_SETTINGS_MODULE=bakerydemo.settings.production \
    DJANGO_DEBUG=off \
    DJANGO_SECRET_KEY=rackcensus-wagtail-bench-not-a-secret \
    SECURE_SSL_REDIRECT=false \
    DATABASE_URL=postgres://app_user:changeme@wagtail-db/app_db \
    REDIS_URL=redis://wagtail-redis
EXPOSE 8000
RUN DATABASE_URL=postgres://none REDIS_URL=none python manage.py collectstatic --noinput \
    && mkdir -p /code/bakerydemo/media/images /code/bakerydemo/media/original_images \
    && chown -R 1000:2000 /code/bakerydemo/media \
    && python -c 'import wagtail, django; assert wagtail.__version__ == "8.0", wagtail.__version__; assert django.__version__ == "6.0.9", django.__version__' \
    && uwsgi --version | grep -qx 2.0.31

FROM postgres:18.6@sha256:fc973eb97c9fd04bfa1840e0f510719a584ccb3be8debfe6a4144637a9dfe8cf AS seed

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends libexpat1 libjpeg62-turbo libpcre2-posix3 shared-mime-info zlib1g \
 && rm -rf /var/lib/apt/lists/*
COPY --from=app /usr/local /usr/local
COPY --from=app /venv /venv
COPY --from=app /code /code
COPY seed/ /seed/
ENV VIRTUAL_ENV=/venv PATH=/venv/bin:$PATH PYTHONPATH=/code/
RUN /seed/seed.sh

FROM scratch AS wagtail-seed
COPY --from=seed /out/ /

FROM app AS wagtail-app

COPY rootfs/ /
COPY --from=wagtail-seed --chown=1000:2000 media/ /code/bakerydemo/media/
COPY --from=wagtail-seed wagtail.json /usr/share/rackcensus/wagtail.json
VOLUME ["/code/bakerydemo/media/images/"]
ENTRYPOINT ["/code/docker-entrypoint.sh"]
CMD ["uwsgi", "/code/etc/uwsgi.ini"]
