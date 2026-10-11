#!/bin/bash
set -euo pipefail

out=/out
datadir=/tmp/mysql
socket=/tmp/mysql.sock
ghost=/var/lib/ghost

sql() {
  mysql --socket="$socket" -uroot "$@"
}

mkdir -p "$out" "$datadir"
chown mysql:mysql "$datadir"
mysqld --initialize-insecure --user=mysql --datadir="$datadir" 2> /tmp/mysql-init.log
mysqld --user=mysql --datadir="$datadir" --socket="$socket" --bind-address=127.0.0.1 --port=3306 \
  --mysqlx=OFF --log-error=/tmp/mysql.log &
for _ in $(seq 1 90); do
  mysqladmin --socket="$socket" -uroot ping > /dev/null 2>&1 && break
  sleep 1
done
mysqladmin --socket="$socket" -uroot ping > /dev/null
sql -e "CREATE DATABASE ghost; CREATE USER 'ghost'@'%' IDENTIFIED BY 'ghost'; GRANT ALL ON ghost.* TO 'ghost'@'%';"

mkdir -p "$ghost/content"
cp -a "$ghost/content.orig/." "$ghost/content/"
cd "$ghost"
export NODE_ENV=production
export url=http://127.0.0.1:2368
export server__host=127.0.0.1
export database__client=mysql
export database__connection__host=127.0.0.1
export database__connection__user=ghost
export database__connection__password=ghost
export database__connection__database=ghost
export security__staffDeviceVerification=false
export logging__transports='["stdout"]'
export logging__level=warn
echo "starting ghost $(node -p 'require("./current/package.json").version') for the seed"
node current/index.js > /tmp/ghost.log 2>&1 &
ghost_pid=$!

node /seed/seed.js http://127.0.0.1:2368 /tmp/ghost-manifest.json || { tail -50 /tmp/ghost.log >&2; exit 1; }
kill "$ghost_pid"
wait "$ghost_pid" || true

echo "exporting database"
mysqldump --socket="$socket" -uroot --single-transaction --skip-dump-date --skip-comments --hex-blob \
  --default-character-set=utf8mb4 --no-tablespaces --set-gtid-purged=OFF ghost | gzip -9 -n > "$out/seed.sql.gz"
mysql_version=$(mysqld --version)
mysqladmin --socket="$socket" -uroot shutdown

node -e '
  const fs = require("fs");
  const crypto = require("crypto");
  const [manifest, dump, mysql, target] = process.argv.slice(1);
  const data = JSON.parse(fs.readFileSync(manifest, "utf8"));
  data.versions.mysql = mysql.match(/Ver ([0-9.]+)/)[1];
  data.versions.node = process.versions.node;
  data.dump_sha256 = crypto.createHash("sha256").update(fs.readFileSync(dump)).digest("hex");
  fs.writeFileSync(target, JSON.stringify(data, null, 2) + "\n");
' /tmp/ghost-manifest.json "$out/seed.sql.gz" "$mysql_version" "$out/ghost.json"
cat "$out/ghost.json" | head -40
echo "seed done: $(du -h "$out/seed.sql.gz" | cut -f1) dump"
