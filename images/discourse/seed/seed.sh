#!/usr/bin/env bash
set -euo pipefail

out=/out
mkdir -p "$out"
set -a
source /etc/rackcensus-discourse.env
set +a

/usr/local/bin/rc-discourse-services start
gem install --no-document gabbler -v 0.1.0
install -m 0644 /seed/seed.rb /tmp/rc-seed.rb
install -d -o discourse /tmp/rc-seed-out
cd /var/www/discourse
su discourse -c "RAILS_ENV=production bundle exec ruby /tmp/rc-seed.rb /tmp/rc-seed-out/discourse.json"
su postgres -c "pg_dump --format=custom --no-comments --file=/tmp/discourse.dump discourse"
/usr/local/bin/rc-discourse-services stop

cp /tmp/discourse.dump "$out/discourse.dump"
ruby -rjson -rdigest -e '
  manifest = JSON.parse(File.read(ARGV[0]))
  manifest["dump_sha256"] = Digest::SHA256.file(ARGV[1]).hexdigest
  File.write(ARGV[2], JSON.pretty_generate(manifest) + "\n")
' /tmp/rc-seed-out/discourse.json "$out/discourse.dump" "$out/discourse.json"
cat "$out/discourse.json"
