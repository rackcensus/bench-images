#!/bin/bash
set -euo pipefail

out=/out
pgdata=/tmp/pgdata
mkdir -p "$out" "$pgdata"
chown postgres:postgres "$pgdata"
su postgres -c "initdb --auth=trust -D $pgdata" > /tmp/initdb.log
su postgres -c "pg_ctl -D $pgdata -l /tmp/postgres.log -o '-c listen_addresses=127.0.0.1' -w start"
su postgres -c "psql -q -c \"CREATE ROLE app_user LOGIN PASSWORD 'changeme'\" -c 'CREATE DATABASE app_db OWNER app_user'"

export DATABASE_URL=postgres://app_user:changeme@127.0.0.1/app_db
export DJANGO_SETTINGS_MODULE=bakerydemo.settings.production
export DJANGO_SECRET_KEY=rackcensus-wagtail-bench-not-a-secret
export SECURE_SSL_REDIRECT=false
export DJANGO_LOG_LEVEL=WARNING
cd /code
python manage.py migrate --noinput -v 0
python manage.py load_initial_data
python /seed/seed.py random
python manage.py update_index -v 0
python manage.py rebuild_references_index -v 0
python /seed/seed.py manifest /tmp/wagtail.json

echo "exporting database"
su postgres -c "pg_dump --no-owner --no-privileges --no-comments app_db" | gzip -9 -n > "$out/seed.sql.gz"
postgres_version=$(su postgres -c "psql -tAc 'SHOW server_version'")
su postgres -c "pg_ctl -D $pgdata -m fast -w stop"

cp -a /code/bakerydemo/media "$out/media"
python - /tmp/wagtail.json "$out/seed.sql.gz" "$postgres_version" "$out/wagtail.json" <<'PY'
import hashlib, json, sys
manifest, dump, postgres, target = sys.argv[1:]
data = json.load(open(manifest))
data["versions"]["postgres"] = postgres.split()[0]
data["dump_sha256"] = hashlib.sha256(open(dump, "rb").read()).hexdigest()
json.dump(data, open(target, "w"), indent=2)
open(target, "a").write("\n")
PY
python -c 'import json, sys; m = json.load(open(sys.argv[1])); print(m["counts"], m["versions"])' "$out/wagtail.json"
echo "seed done: $(du -h "$out/seed.sql.gz" | cut -f1) dump, $(find "$out/media" -type f | wc -l) media files"
