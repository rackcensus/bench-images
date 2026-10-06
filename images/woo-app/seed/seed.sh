#!/bin/bash
set -euo pipefail

docroot=/var/www/html
out=/out
socket=/run/mysqld/mysqld.sock

wp() {
  php -d memory_limit=1024M -d opcache.enable_cli=0 /usr/local/bin/wp-cli.phar --allow-root --path="$docroot" "$@"
}

sql() {
  mariadb --socket="$socket" "$@"
}

mkdir -p /run/mysqld "$out"
chown mysql:mysql /run/mysqld
mariadb-install-db --user=mysql --datadir=/var/lib/mysql --skip-test-db > /dev/null
mariadbd --user=mysql --datadir=/var/lib/mysql --socket="$socket" --skip-networking \
  --innodb-buffer-pool-size=256M --log-error=/tmp/mariadb.log &
for _ in $(seq 1 60); do
  mariadb-admin --socket="$socket" ping > /dev/null 2>&1 && break
  sleep 1
done
mariadb-admin --socket="$socket" ping > /dev/null
sql -e "CREATE DATABASE woocommerce CHARACTER SET utf8mb4; CREATE USER 'woo'@'localhost' IDENTIFIED BY 'woo'; GRANT ALL ON woocommerce.* TO 'woo'@'localhost';"

sed -i "s#define( 'DB_HOST', 'woo-db' );#define( 'DB_HOST', 'localhost:$socket' );#" "$docroot/wp-config.php"
grep -q "localhost:$socket" "$docroot/wp-config.php"
mkdir -p "$docroot/wp-content/mu-plugins"
cp /seed/rc-seed.php "$docroot/wp-content/mu-plugins/"
php -r '$z = new ZipArchive(); if ($z->open($argv[1]) !== true || !$z->extractTo($argv[2])) { exit(1); }' \
  /seed/wordpress-importer.zip "$docroot/wp-content/plugins"

echo "installing wordpress"
wp core install --url=http://woo --title="RackCensus Store" --admin_user=admin \
  --admin_password="$(head -c 24 /dev/urandom | base64)" --admin_email=admin@example.com --skip-email
wp rewrite structure '/%postname%/'
test "$(wp option get stylesheet)" = twentytwentyfive
wp plugin activate woocommerce
wp plugin activate wordpress-importer

echo "configuring woocommerce"
wp option update woocommerce_coming_soon no
wp option update woocommerce_store_pages_only no
wp option update woocommerce_default_country US:CA
wp option update woocommerce_currency USD
wp option update woocommerce_default_customer_address base
wp option update woocommerce_allow_tracking no
wp wc payment_gateway update cod --enabled=true --user=admin > /dev/null
wp wc shipping_zone_method create 0 --method_id=flat_rate --enabled=true --settings='{"cost":"5.00"}' --user=admin > /dev/null

echo "importing sample products"
wp import "$docroot/wp-content/plugins/woocommerce/sample-data/sample_products.xml" --authors=create
wp plugin deactivate wordpress-importer

clothing=$(wp term get product_cat clothing --by=slug --field=term_id)
for slug in accessories hoodies tshirts; do
  wp term update product_cat "$(wp term get product_cat "$slug" --by=slug --field=term_id)" --parent="$clothing" > /dev/null
done

home_id=$(wp post create /seed/home.html --post_type=page --post_status=publish --post_title=Home --post_name=home --porcelain)
wp option update show_on_front page
wp option update page_on_front "$home_id"

wp wc tool run recount_terms --user=admin > /dev/null
wp wc tool run regenerate_product_lookup_tables --user=admin > /dev/null
wp wc tool run regenerate_product_attributes_lookup_table --user=admin > /dev/null

wp action-scheduler migrate

echo "draining action scheduler"
soon() {
  date -u -d '+2 minutes' '+%Y-%m-%d %H:%M:%S'
}
for round in $(seq 1 60); do
  hooks=$(wp action-scheduler action list --status=pending --date="$(soon)" --date-compare='<=' --field=hook --format=csv)
  if [ -z "$hooks" ]; then
    break
  fi
  echo "round $round: running $(echo "$hooks" | sort | uniq -c | awk '{printf "%s%s x%s", sep, $2, $1; sep=", "}')"
  wp action-scheduler run --batch-size=100 --batches=0 --force --quiet
  sleep 2
done
due=$(wp action-scheduler action list --status=pending --date="$(soon)" --date-compare='<=' --format=count)
if [ "$due" -ne 0 ]; then
  echo "action scheduler still has $due actions due within two minutes after draining" >&2
  exit 1
fi
failed=$(wp action-scheduler action list --status=failed --format=count)
future=$(wp action-scheduler action list --status=pending --format=count)
echo "action scheduler drained, $failed failed and $future scheduled for later: $(wp action-scheduler action list --status=pending --field=hook --format=csv | tr '\n' ' ')"
if [ "$failed" -ne 0 ]; then
  wp action-scheduler action list --status=failed --fields=hook --format=csv
fi

rm -f "$docroot/wp-content/mu-plugins/rc-seed.php"
rmdir "$docroot/wp-content/mu-plugins" 2> /dev/null || true
wp rewrite flush
wp option delete woocommerce_queue_flush_rewrite_rules > /dev/null 2>&1 || true
wp transient delete --all

if [ "$(wp option get action_scheduler_migration_status)" != complete ]; then
  echo "action scheduler migration did not complete" >&2
  exit 1
fi

wp eval-file /seed/manifest.php > "$out/woocommerce.json"
php -r '$m = json_decode(file_get_contents($argv[1]), true); foreach (["product_ids", "product_paths", "category_paths", "search_terms"] as $k) { if (empty($m[$k])) { fwrite(STDERR, "manifest has no $k\n"); exit(1); } }' "$out/woocommerce.json"
cat "$out/woocommerce.json"

echo "exporting database"
mariadb-dump --socket="$socket" --single-transaction --skip-dump-date --skip-comments --hex-blob \
  --default-character-set=utf8mb4 --no-tablespaces woocommerce | gzip -9 -n > "$out/seed.sql.gz"
mariadb-admin --socket="$socket" shutdown

find "$docroot/wp-content/uploads/wc-logs" -name "*.log" -delete
cp -a "$docroot/wp-content/uploads" "$out/uploads"
cp /seed/images/index.json "$out/sample-images.json"
echo "seed done: $(du -sh "$out/seed.sql.gz" | cut -f1) dump, $(find "$out/uploads" -type f | wc -l) upload files"
