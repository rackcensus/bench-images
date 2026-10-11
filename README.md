# bench-images

These are the container images and pinned downloads that RackCensus benchmark runs pull onto a fresh VPS. Each release attaches an `images.json` manifest, and a box only ever pulls what that manifest names, by platform digest. Nothing on a box resolves a tag.

Everything here is built or copied for `linux/amd64` and `linux/arm64`, and every image lives under `ghcr.io/rackcensus/`.

## What's in a release

| Image | Used for | Where it comes from |
| --- | --- | --- |
| `wrk` | HTTP load for the framework tests | Ubuntu 24.04 with `wrk 4.1.0-4build2` and curl from apt, the same recipe as TechEmpower's `toolset/wrk` |
| `sysbench` | MySQL OLTP | Ubuntu 24.04 with `sysbench 1.0.20+ds-6build2` from apt |
| `memtier` | Redis load | `memtier_benchmark` 2.5.1 built from source at commit `5f634d1` |
| `tfb-postgres` | Database for the framework tests | TechEmpower's Postgres toolset at upstream commit `57d92fb`, on `postgres:18.6` |
| `woo-app` | WooCommerce store, web tier | php-fpm 8.4.26, nginx 1.26, tini; WordPress 7.1.2, WooCommerce 11.1.2, Twenty Twenty-Five 1.5 |
| `woo-db` | WooCommerce store, database | MariaDB 12.3.3 (the current LTS) with the seeded store loaded on first start |
| `discourse` | Discourse forum, the whole stack in one container | Discourse's own standalone install (`discourse/base:2.0.20260915-0028`, `discourse_docker` at `ac99052`, Discourse at `7d3d93e`, `docker_manager` at `0d26dda`) with a seeded forum baked in |
| `ghost-app` | Ghost blog, app | `ghost:6.69.0-alpine` (Node 22.23.3), the image Ghost's own `ghost-docker` setup runs, with the run config baked in |
| `wagtail-app` | Wagtail site, app | Wagtail's `bakerydemo` at `c8f8255` built with its own production Dockerfile: `python:3.12.15-slim-trixie`, uWSGI 2.0.31, Wagtail 8.0, Django 6.0.9, with locked and hashed requirements |
| `wagtail-db` | Wagtail site, database | `postgres:18.6` with the seeded bakery loaded on first start |
| `ghost-db` | Ghost blog, database | `mysql:8.0.44`, the version and digest `ghost-docker` pins, with the seeded blog loaded on first start |
| `postgres` | Dedicated Postgres tests | Copy of `postgres:18.6` |
| `mysql` | sysbench target | Copy of `mysql:8.4.11` |
| `redis` | memtier target | Copy of `redis:8.10.2` |
| `mariadb` | Base of `woo-db` | Copy of `mariadb:12.3.3` |
| `k6` | WooCommerce load | Copy of `grafana/k6:2.3.0` |

Every `FROM` line is pinned by digest, and so is every download (WordPress, WooCommerce, WP-CLI and the WordPress importer go through `ADD --checksum`).

Releases also carry `images.json` and `SHA256SUMS`, plus copies of `pts.tar.gz` (the Phoronix Test Suite at commit `be12163`) and the two source tarballs PTS fetches for `pts/stream-1.3.4` and `pts/schbench-1.2.0`. The repository is private, so boxes can't download release assets. They pull those three files from `ghcr.io/rackcensus/pts-assets` instead (more on that below).

## The built images

### wrk

Plain wrk. One quirk worth knowing: the base image has no `/etc/services`, so wrk can't turn `http` into a port number. Always put the port in the URL (`http://tfb-server:8080/json`, not `http://tfb-server/json`).

### sysbench

sysbench 1.0.20 as Ubuntu ships it, linked against `libmysqlclient21`. MySQL 8.4 defaults to `caching_sha2_password`, and that plugin wants either TLS or a unix socket for the full handshake (sysbench 1.0.20 can't do the RSA key exchange over plain TCP). So run MySQL with its socket directory on a named volume, mount the same volume into the sysbench container, and pass `--mysql-socket=/var/run/mysqld/mysqld.sock`. CI does exactly that.

### memtier

Built from a commit, checked against the expected sha, then copied into a slim Ubuntu image with only the runtime libraries. The GPL license file ships in `/usr/share/doc/memtier-benchmark/`.

### tfb-postgres

Same schema and data as TechEmpower's Postgres image: `World`/`world` with 10,000 rows each and `Fortune`/`fortune` with the 12 standard fortunes, owned by `benchmarkdbuser` in `hello_world`. Two things changed.

`pg_stat_statements` is no longer preloaded. The extension still gets created (that part of the schema is untouched), so TechEmpower's verify mode can count queries again by starting the container with `-c shared_preload_libraries=pg_stat_statements`.

The config defaults are sized for a small box (100 connections, 128 MB shared buffers, 4 MB work_mem, 512 MB effective cache) instead of TechEmpower's 28-core numbers, and everything is meant to be overridden with `postgres -c key=value` arguments, which win over the config file. The durability shortcuts stay: `synchronous_commit=off`, `wal_level=minimal`.

On `postgres:18` the data directory moved to `/var/lib/postgresql/18/docker`, so mount volumes at `/var/lib/postgresql`, not at the old `/var/lib/postgresql/data`.

### woo-app and woo-db

A stock WooCommerce store with no page cache and no object cache, so every request runs PHP and hits the database. That's the point.

The site URL is `http://woo` and WordPress looks for its database at `woo-db:3306` (database `woocommerce`, user and password `woo`). Put both containers on the same network with those aliases:

```sh
docker network create woo
docker run -d --network woo --network-alias woo-db ghcr.io/rackcensus/woo-db@sha256:... \
  --innodb-buffer-pool-size=256M --max-connections=200
docker exec <db> healthcheck.sh --connect --innodb_initialized
docker run -d --network woo --network-alias woo -e RC_CPUS=2 -e RC_WORKERS=8 ghcr.io/rackcensus/woo-app@sha256:...
```

`woo-db` imports the seed on first start, which took 5 to 12 seconds in testing. Wait for `healthcheck.sh` to pass before starting the app. The two MariaDB flags above override the stock defaults (128 MB buffer pool, 151 connections); anything else `mariadbd` accepts works the same way.

`woo-app` runs nginx and php-fpm under tini and renders both configs at start. `RC_WORKERS` sets the number of php-fpm children (`pm = static`) and `RC_CPUS` sets nginx `worker_processes`. Unset, it uses `nproc` for CPUs and two children per CPU. Anything that isn't a positive integer exits with status 64 and a message. Both servers log to stderr, access logs are off, and if either process dies the container exits.

WordPress runs with `DISABLE_WP_CRON`, `WP_HTTP_BLOCK_EXTERNAL`, `DISALLOW_FILE_MODS` and auto-updates off, so a run never phones home or changes itself halfway through. OPcache is on with `validate_timestamps=0` (the files never change inside the container); JIT is off.

### The WooCommerce seed

The seed is a build stage (`woo-seed` in `images/woo-app/Dockerfile`). It starts a throwaway MariaDB, then:

1. Installs WordPress at `http://woo`, sets `/%postname%/` permalinks and keeps Twenty Twenty-Five.
2. Activates WooCommerce, turns coming soon mode off (`woocommerce_coming_soon=no`), sets a US store in USD, and turns on cash on delivery and a $5 flat rate so cart and checkout have something to show.
3. Imports WooCommerce's own `sample_products.xml` with the WordPress importer. The 22 product photos get fetched once up front; if any of them 404 it generates an 800x800 placeholder JPEG so pages keep a realistic weight. The import is then served from those local copies, so nothing else reaches the network.
4. Puts Accessories, Hoodies and Tshirts back under Clothing. The XML doesn't carry the category tree but WooCommerce's CSV version of the same catalog does.
5. Adds a Home page with a product collection and the category list, and makes it the front page.
6. Recounts terms, rebuilds the product lookup tables, finishes the Action Scheduler table migration and drains every action that's due within the next two minutes. The build fails if anything is still due.
7. Dumps the database and writes `woocommerce.json` with what the load test needs.

`woocommerce.json` ends up in both images at `/usr/share/rackcensus/woocommerce.json` and in the release manifest. It has `product_ids` (simple, purchasable, in-stock products for `/?add-to-cart=ID`), `product_paths`, `category_paths`, `search_terms` (only terms with at least two hits, since WooCommerce redirects a single-result search straight to the product), the store page paths and the versions.

CI builds the seed once and hands the same directory to both architectures, so amd64 and arm64 serve byte-identical data. `woo-app` takes the generated uploads from it and `woo-db` takes the dump.

The cart and checkout pages are WooCommerce's block versions. They render the cart server side as preloaded Store API data, so a cart check looks for `%22items_count%22%3A1%2C` and the URL-encoded `"id":<product>,` in the HTML rather than a product name in a table.

### discourse

This is the container a person gets from Discourse's own install guide: `postgres`, `redis` and `web` templates fed through `pups` on top of `discourse/base`, the same thing `./launcher bootstrap app` does. Postgres 18, Redis, nginx, the app server and Sidekiq all run inside it under runit, so a box sees one container, the way a real install looks.

`images/discourse/bootstrap` rebuilds what the launcher does: it concatenates the templates and `app.yml` with the launcher's separator, works out the merged `env` block, and pipes the result into `pups --stdin`. It runs inside `docker build`, which `launcher` can't, and the build checks that the Discourse and `docker_manager` commits it ended up on are the pinned ones. The merged environment lands in `/etc/rackcensus-discourse.env` because the launcher would have passed it as `-e` flags at run time.

Three things differ from the sample `standalone.yml`, all on purpose:

- `web.ratelimited.template.yml` is left out and `DISCOURSE_MAX_REQS_PER_IP_MODE=none` is set. Both limit requests per IP address, and every request in a benchmark comes from one IP. The defaults allow 50 requests per 10 seconds, so the load generator would be blocked almost immediately.
- The hostname is `discourse`, so the container answers on a Docker network without DNS. Mail goes nowhere (`DISCOURSE_SKIP_EMAIL_SETUP=1`).
- `docker_manager` is checked out at a fixed commit instead of whatever `main` is at build time.

Everything else stays stock, including the parts that change the numbers: the anonymous page cache in Redis, the overload protection that sheds anonymous requests once the queue is a second deep, `PRECOMPILE_ON_BOOT`, and the GC settings from `web.template.yml`.

`RC_WORKERS` sets `UNICORN_WORKERS` and `RC_DB_SHARED_BUFFERS` (like `256MB`) rewrites `shared_buffers` in `/etc/postgresql/18/main/postgresql.conf`. Postgres reads that file, not the copy under `/shared/postgres_data`. Anything malformed exits with status 64. Unset, it keeps the bootstrap values: 2 workers and 128 MB.

```sh
docker network create forum
docker run -d --network forum --name discourse --shm-size=512m \
  -e RC_WORKERS=4 -e RC_DB_SHARED_BUFFERS=256MB ghcr.io/rackcensus/discourse@sha256:...
docker exec discourse curl -s -H 'Host: discourse' http://127.0.0.1/srv/status
```

It answers within about 15 seconds. Send a browser `User-Agent`, because Discourse serves its stripped down crawler page to anything else, and that includes `ab`, curl and k6's default. Discourse's own `script/bench.rb` measures the crawler page for exactly that reason.

### The Discourse seed

The seed is a build stage (`discourse-seed`). It runs `seed/seed.rb`, which is Discourse's `script/profile_db_generator.rb` adapted to the production environment (GPLv2 like the original, see `seed/NOTICE`): 100 users plus `admin1`, 10 categories, 100 topics with 2,000 replies, and the perf test topic with 100 replies, with the random generator seeded so the content comes out the same way every time. It also raises the login rate limits so a few hundred virtual users can sign in from one address, then dumps the database with `pg_dump --format=custom`.

`discourse.json` records the topic path, the usernames and their shared password, the counts, the versions and the dump's sha256. The final stage restores the dump into a fresh database, checks the user count and the sha, and copies `discourse.json` to `/usr/share/rackcensus/discourse.json`. Like the WooCommerce seed, CI builds it once on amd64 and hands the same dump to both architectures.

The image is about 4 GB unpacked and 1.6 GB compressed, the largest one here by a wide margin.

### ghost-app and ghost-db

These follow Ghost's official self-hosting setup, [`ghost-docker`](https://github.com/TryGhost/ghost-docker): the `ghost` image on Alpine and MySQL 8.0 with stock settings, nothing tuned. Ghost has no worker setting, it's one Node process, and `ghost-docker` leaves MySQL at its defaults (a 128 MB InnoDB buffer pool), so there's nothing to size per box. That's the point: this is what a person who follows Ghost's guide ends up running.

What's different from `ghost-docker`:

- No Caddy in front. It only terminates TLS there. Ghost answers on port 2368 and its `url` is `http://ghost`, so it works on a Docker network without DNS.
- `security__staffDeviceVerification=false`. Ghost 6 emails a code to staff signing in from a new device, which a load generator can't read. A real editor's browser gets remembered after the first code, so turning it off matches day to day use.
- ActivityPub and Tinybird analytics are left off, as they are in `ghost-docker` until you opt in.
- Mail goes nowhere.

`ghost-app` ships `rc-ghost-status <path>`, which prints the status code Ghost returns for a path, because the Alpine image has no curl. Ghost is ready once `/ghost/api/admin/site/` answers 200.

```sh
docker network create blog
docker run -d --network blog --name ghost-db ghcr.io/rackcensus/ghost-db@sha256:...
docker exec ghost-db mysqladmin ping -h 127.0.0.1 -uroot -pghost --silent
docker run -d --network blog --name ghost ghcr.io/rackcensus/ghost-app@sha256:...
docker exec ghost rc-ghost-status /ghost/api/admin/site/
```

Start the database first and wait until it answers over TCP. The MySQL entrypoint loads the seed with networking off, so TCP only answers once the seed is in. Ghost exits if it can't reach the database when it starts.

### wagtail-app and wagtail-db

These follow [`bakerydemo`](https://github.com/wagtail/bakerydemo), Wagtail's official demo site, the way its production Dockerfile and `docker-compose.yml` run it: uWSGI from `etc/uwsgi.ini`, Postgres, and Redis as the Django cache. Its `uwsgi.ini` fixes uWSGI at 2 workers with 4 threads each, whatever the box, and Postgres and Redis run on stock settings. Nothing here changes that, so on a 4 or 8 vCPU box this setup leaves cores idle, which is what a person copying the demo gets.

What's different from bakerydemo:

- Requirements come from `requirements.lock`, which `uv pip compile --universal --generate-hashes` resolved from `requirements/production.txt` with `--exclude-newer 2026-10-10`, so a rebuild gets the same packages. The upstream Dockerfile resolves the version ranges at build time.
- `SECURE_SSL_REDIRECT=false`, because there's no TLS in front, and a fixed `DJANGO_SECRET_KEY` that isn't a secret.
- Postgres is 18.6 and Redis is 8.10.2, the mirrors used elsewhere here, instead of the compose file's 18.1 and 8.4.

Redis isn't its own image: the agent runs the `redis` mirror as `wagtail-redis`. `wagtail-app` ships `rc-wagtail-status <path>`, which prints the status code for a path because the slim image has no curl.

uWSGI's `http-socket` closes the connection after every response even though `uwsgi.ini` sets `http-keepalive`. A client that reuses the connection gets a reset. Browsers and Go's HTTP client retry a GET on a fresh connection without saying so, but not a POST, so the k6 script runs with `noConnectionReuse` and opens a connection per request, which is what this server makes every client do anyway.

### The Wagtail seed

The seed is a build stage (`wagtail-seed`) in `images/wagtail-app`. It copies Python, the virtualenv and the code into `postgres:18.6` (both are Debian trixie), runs the migrations and bakerydemo's `load_initial_data`, then bakerydemo's own `create_random_data 50 20 0`, which its help text describes as useful for load testing. That adds 50 bread, location, blog and standard pages each on top of the demo content, about 235 live pages in all, reusing the demo's images. `seed/seed.py` then crawls every live page and the search page once, so the 600 or so image renditions exist before the first measured request, and checks the admin editor answers. The database goes out through `pg_dump --no-owner`, and the media directory, renditions included, gets copied into `wagtail-app`.

`wagtail.json` records the page paths, the search terms, the page ids the editor test opens, the admin login (`admin`, bakerydemo's documented password), the counts, the versions and the dump's sha256.

### The Ghost seed

The seed is a build stage (`ghost-seed`) in `images/ghost-app`. Ghost needs MySQL to build its schema, and MySQL 8.0 isn't packaged for Alpine, so the stage starts from the same `mysql:8.0.44` image and copies Node and Ghost out of the Debian `ghost:6.69.0` image, which is the same Ghost release built against glibc. `seed/seed.js` drives Ghost's own Admin API: it sets up the owner, then creates 10 tags, 200 published posts spread over two years, 20 drafts and 1,000 members, with a seeded random generator so the content comes out the same every time. Ghost's default "Coming soon" post and "Getting Started" tag stay, the way a fresh install has them. Then it dumps the database with `mysqldump`.

`ghost.json` records the post, tag and author paths, the draft ids the staff test edits, the owner's login, the counts, the versions and the dump's sha256. Both images carry the same `ghost.json`, and the verify job refuses a pair built from different seeds.

## Mirrors

The five mirrored images are copied with `docker buildx imagetools create` from the platform digests in `mirrors.lock`. Nothing gets rebuilt, so the amd64 and arm64 digests on GHCR are the same digests Docker Hub serves. Only the index differs, because it carries two platforms and a source annotation. `scripts/resolve-images` refuses to continue if a mirrored platform digest doesn't match the lock.

Redis 8 is licensed under RSALv2, SSPLv1 or AGPLv3, and k6 under AGPLv3. Their layers are copied untouched, license files included, and the source is wherever upstream publishes it.

If Docker Hub refuses a copy (rate limits happen), `scripts/mirror` retries through `mirror.gcr.io`. That's safe because the digests are content addresses. The CI builders read Docker Hub through the same mirror for base images.

## Phoronix Test Suite

`pts.lock` pins the PTS commit and the files PTS would otherwise download. `scripts/pts-archive` rebuilds `pts.tar.gz` with `git archive --prefix=phoronix-test-suite/` and `gzip -9 -n` inside the pinned Ubuntu image, then checks both the tar and the gzip hashes against the lock. The tar comes out identical from git 2.43 and git 2.50, so the asset is byte-stable and anyone can reproduce the hash. The stream and schbench tarballs are fetched from phoronix-test-suite.com and checked the same way.

Boxes get the three files from `ghcr.io/rackcensus/pts-assets`, an OCI artifact where each file is its own raw blob (`application/octet-stream`, not tarred), so a blob's digest is the file's sha256. `scripts/push-pts-assets` uploads the files and writes the manifest itself rather than going through oras, which keeps the manifest byte-stable: same files, same manifest digest, every time. That digest is pinned in `pts.lock` under `assets`, and the script refuses to push anything that doesn't hash to it. It tags the manifest `10.8.6-be12163`, plus any `--tag` you pass, and reads the token from stdin:

```sh
scripts/pts-archive build/pts
gh auth token | scripts/push-pts-assets build/pts --user <your github login>
```

Pass `--digest-only` to print the manifest digest without pushing, which is how you get the new value for `pts.lock` after bumping PTS.

Downloading a file anonymously takes two requests, because GHCR wants a bearer token even for public packages. Without one, the blob URL returns 401.

```sh
token=$(curl -s 'https://ghcr.io/token?scope=repository:rackcensus/pts-assets:pull' | jq -r .token)
curl -fsSL -H "Authorization: Bearer $token" -o pts.tar.gz \
  https://ghcr.io/v2/rackcensus/pts-assets/blobs/sha256:adca64f6e9a9c500b81b36a207f46aad633575c98c5508caca607742cb8797f4
```

The blob URL redirects to `pkg-containers.githubusercontent.com`. Sending the Authorization header along on that redirect works, and so does dropping it.

PTS at `be12163` already carries `pts/stream-1.3.4` and `pts/schbench-1.2.0` in its `ob-cache`, so a box needs no OpenBenchmarking.org access as long as it points `PTS_DOWNLOAD_CACHE` at the two tarballs.

## Workflows

`build.yml` runs by hand and from `release.yml`. It used to run on every push, but the repository is private now and runner minutes on private repositories aren't free. It builds the WooCommerce seed once on amd64, then builds every image natively on `ubuntu-24.04` and `ubuntu-24.04-arm`, pushes each one by digest, merges the two digests into one index tagged with the commit sha (and `main` on main), copies the mirrors, and resolves every digest into `images-resolved.json`. It then calls the next two workflows.

`verify.yml` pulls every image by its platform digest on both architectures, records the unpacked size, and runs each tool at a tiny scale the way a benchmark run will:

- wrk against an nginx container on a private network
- sysbench `oltp_read_write` and `oltp_read_only` against the MySQL mirror over a unix socket, resetting binary logs between runs
- memtier at 1:10 and 1:1 against the Redis mirror after a 10,000 key prefill
- pg_test_fsync, `pgbench -i`, and pgbench read-write and select-only with sampled logs against the Postgres mirror, then the `tfb-postgres` schema, the `-c` overrides and the missing preload
- k6 against `discourse` with 2 workers: the signed in and anonymous mixes for 15 seconds each, failing on any failed check or failed request, while the container's memory gets sampled
- k6 against `ghost-app` and `ghost-db`: readers (home, post, tag, author and RSS pages) and staff in Ghost Admin (post list, post editor, saving a draft, member list) for 15 seconds each, failing on any failed check or any failed request in a measured step, while both containers' memory gets sampled. Ghost sometimes answers several staff signing in at the same moment with a MySQL deadlock, so the k6 script retries a sign-in up to five times. Sign-ins aren't measured.
- k6 against `wagtail-app`, `wagtail-db` and the Redis mirror: visitors (home, blog index, blog post, bread, location and search pages) and editors signed into the Wagtail admin (dashboard, page explorer, page editor, image library, page search) for 15 seconds each, after checking uWSGI runs a master and 2 workers. Any failed check or request fails the job.
- k6 against `woo-app` and `woo-db`: a page mix of home, shop, category, product and search, then a cart flow of `/?add-to-cart=ID`, cart and checkout with a fresh cookie jar per iteration, checking the `woocommerce_items_in_cart` cookie, the cart contents and the checkout block. Any failed check or failed request fails the job.

While k6 runs, a sidecar that shares the app's PID namespace (with `SYS_PTRACE` and nothing else) samples `smaps_rollup` for every php-fpm child. RSS counts the shared OPcache memory in every child, so the job records RSS, PSS and private memory side by side. The manifest's `rss_proc_mb` carries PSS, rounded up, because that's what the sizing math wants (the field kept its name for compatibility). `memory` has all three.

`anon-pull.yml` resolves the digests with credentials in one job, then a second job with no registry login fetches an anonymous token and every manifest, and pulls one image with an empty Docker config. It also downloads every PTS file from `pts-assets` with an anonymous token and checks each one against `pts.lock`. If a package is private or missing, it names the package and fails.

`release.yml` runs by hand with a `tag` input. It runs the whole build, verify and anon-pull chain against the selected commit, builds the PTS files, pulls `frameworks.json` from the fork release pinned in `frameworks.lock`, assembles `images.json`, tags every image with the release name, writes `SHA256SUMS`, and creates the GitHub release along with its tag. It doesn't push `pts-assets`, and anon-pull stops the release if the pinned files aren't there.

## Cutting a release

Releases run from a laptop. `scripts/release` does what the Actions chain does, without the runner minutes:

```sh
scripts/release v2026.10.07-1
scripts/release v2026.10.07-1 --publish
```

It won't start with a dirty tree or with a HEAD that isn't on `origin/main`. It logs in to GHCR with your `gh` token through a throwaway Docker config, so your own Docker login stays untouched. From there it:

- builds the seed and all six images for both architectures through an `rc-release` buildx builder (created on first use and kept around for its cache)
- pushes them by digest, merges each pair into an index tagged with the commit sha, and copies the mirrors
- resolves every digest and runs the full verify suite against each architecture
- reads the seed manifest out of `woo-app`, builds the PTS files, merges the pinned `frameworks.json`, and assembles `images.json` and `SHA256SUMS` under `build/release/<tag>/assets`

Without `--publish` it stops there and you can read the manifest. With `--publish` it checks every package for anonymous access (`pts-assets` included), tags every image with the release name, and creates the GitHub release and its tag at HEAD. Push `pts-assets` first; the release script doesn't.

On Apple silicon the amd64 checks run under emulation. They pass, but throughput comes out lower and php-fpm PSS reads about 40% high, so the script prints a warning when that happens and the amd64 memory numbers in that release are conservative.

To release images that are already built and verified, skip both steps:

```sh
scripts/release v2026.10.07-1 --built <image tag> --verify verify-amd64.json --verify verify-arm64.json --publish
```

Verify results now record the digests they checked, and the script refuses a file that covers different digests. Results from before that change don't record them, so the script takes your word for it and says so.

The `-N` suffix is for a second release on the same day. `release.yml` still works by hand (`gh workflow run release.yml -f tag=v2026.10.07-1`) if paying for runners is fine.

The app copies the release's `images.json` into `config/bench_images.json` and pins its sha256.

## Framework images

The `tfb-*` images come from `rackcensus/FrameworkBenchmarks`, which builds them, verifies them with TechEmpower's own verifier, measures memory per process, and publishes a `frameworks.json` release asset. `frameworks.lock` pins which fork release (and which sha256 of that asset) goes into a bench-images release. With no fork release pinned, the manifest ships with `"frameworks": []` and `"fork": {"sha": null}`. Once it's pinned, the release merges that file's `images` and `frameworks` into the manifest and fails on a name clash, a missing key or a framework that points at an image nobody built.

## images.json

Schema 1, as the app expects it:

```json
{
  "schema": 1,
  "release": "v2026.10.07-1",
  "registry_token_url": "https://ghcr.io/token?scope=repository:rackcensus/pts-assets:pull",
  "fork": {"repo": "rackcensus/FrameworkBenchmarks", "sha": null},
  "pts": {"commit": "be12163...", "version": "10.8.6",
          "file": "pts.tar.gz", "sha256": "adca64f6...", "url": "https://ghcr.io/v2/rackcensus/pts-assets/blobs/sha256:adca64f6...",
          "assets": "ghcr.io/rackcensus/pts-assets@sha256:92ea63d4...",
          "downloads": [{"file": "stream-2013-01-17.tar.bz2", "sha256": "c4d82d3a...", "url": "https://ghcr.io/v2/rackcensus/pts-assets/blobs/sha256:c4d82d3a..."}]},
  "images": {
    "wrk": {"repo": "ghcr.io/rackcensus/wrk", "index": "sha256:...",
            "platforms": {"linux/amd64": {"digest": "sha256:...", "compressed_bytes": 0, "unpacked_bytes": 0}, "linux/arm64": {}}}
  },
  "frameworks": [],
  "woocommerce": {"rss_proc_mb": {"amd64": 0, "arm64": 0}, "product_ids": [], "category_paths": [], "search_terms": []},
  "discourse": {"topic_path": "/t/i-am-a-topic-used-for-perf-tests/117", "user_activity_path": "/u/admin1/activity", "usernames": [], "password": "...",
                "counts": {}, "dump_sha256": "...", "versions": {}, "memory": {"amd64": {}, "arm64": {}}},
  "ghost": {"post_paths": [], "tag_paths": [], "author_path": "/author/rack/", "draft_post_ids": [], "staff_email": "owner@example.com", "password": "...",
            "counts": {}, "dump_sha256": "...", "versions": {}, "memory": {"amd64": {}, "arm64": {}}},
  "wagtail": {"home_path": "/", "blog_index_path": "/blog/", "blog_paths": [], "bread_paths": [], "location_paths": [], "search_terms": [],
              "explorer_page_id": 0, "edit_page_ids": [], "username": "admin", "password": "...",
              "counts": {}, "dump_sha256": "...", "versions": {}, "memory": {"amd64": {}, "arm64": {}}}
}
```

Every `url` under `pts` is an anonymous GHCR blob URL, so fetch a token from `registry_token_url` first and send it as a bearer token. `pts.assets` is the artifact manifest those blobs belong to. On top of the contract, mirrored images carry `source` (the Docker Hub tag and index digest they came from), and `woocommerce` carries `product_paths`, `pages`, `versions` and `memory`. `compressed_bytes` is the config plus layers as stored in the registry. `unpacked_bytes` is what `docker image inspect` reports after a pull with the overlay2 store.

## Working locally

```sh
scripts/build-local arm64
```

builds every image for one architecture as `rc/<name>:<arch>`, building the seeds into `build/woo-seed`, `build/discourse-seed`, `build/ghost-seed` and `build/wagtail-seed` the first time. Pass a builder name as the second argument to build through a different buildx builder (handy for amd64 under emulation). To run the checks, write a refs file that maps each image name to a local tag or a digest reference (`wrk`, `sysbench`, `memtier`, `tfb-postgres`, `woo-app`, `woo-db`, `discourse`, `ghost-app`, `ghost-db`, `wagtail-app`, `wagtail-db`, `postgres`, `mysql`, `redis`, `k6`, and optionally `http-server`) and run:

```sh
verify/all.sh build/verify build/refs.json
verify/all.sh build/verify build/refs.json woo
```

The second form runs a subset. Each check cleans up its own containers, volumes and network on the way out.

To bump a mirror, run `scripts/lock-mirrors` with the new tags and commit the output as `mirrors.lock`. Use `--read-through mirror.gcr.io` if Docker Hub is rate limiting you. The resulting digests are identical either way.

## Package visibility

GHCR creates new packages as private and there's no API for changing that. After the first push of a new image (or of `pts-assets`), an org admin has to open the package under the org's Packages tab, go to Package settings, and change visibility to public. The repository being private doesn't change this; the packages still have to be public for boxes to pull them. `anon-pull` keeps failing, and so does every release, until that's done.
