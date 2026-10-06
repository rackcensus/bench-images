FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55 AS build

ARG DEBIAN_FRONTEND=noninteractive
ARG MEMTIER_VERSION=2.5.1
ARG MEMTIER_COMMIT=5f634d171b83efca9640c5a87606c47b34d3d330
RUN apt-get update \
 && apt-get install -y --no-install-recommends autoconf automake build-essential ca-certificates git libevent-dev libssl-dev pkg-config zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git init -q . \
 && git remote add origin https://github.com/redis/memtier_benchmark.git \
 && git fetch -q --depth 1 origin "$MEMTIER_COMMIT" \
 && git checkout -q FETCH_HEAD \
 && test "$(git rev-parse HEAD)" = "$MEMTIER_COMMIT"
RUN autoreconf -ivf >/dev/null \
 && ./configure --quiet \
 && make -j"$(nproc)" \
 && make install DESTDIR=/out \
 && /out/usr/local/bin/memtier_benchmark --version | grep -q "$MEMTIER_VERSION"

FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends libevent-2.1-7t64 libevent-extra-2.1-7t64 libevent-openssl-2.1-7t64 libevent-pthreads-2.1-7t64 libssl3t64 zlib1g \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/usr/local/bin/memtier_benchmark /usr/local/bin/memtier_benchmark
COPY --from=build /src/COPYING /usr/share/doc/memtier-benchmark/COPYING
RUN memtier_benchmark --version
