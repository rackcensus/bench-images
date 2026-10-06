first_word() {
  set -f
  set -- $(tr "\0" " " < "/proc/$1/cmdline" 2> /dev/null)
  set +f
  [ "${1:-}" = "[rosetta]" ] && shift
  basename "${1:-none}"
}

kind() {
  self=$(first_word "$1")
  parent=$(first_word "$(sed "s/.*) //" "/proc/$1/stat" | cut -d" " -f2)")
  case "$self" in
    php-fpm*) case "$parent" in php-fpm*) echo php-fpm-child ;; *) echo php-fpm-master ;; esac ;;
    nginx*) case "$parent" in nginx*) echo nginx-worker ;; *) echo nginx-master ;; esac ;;
  esac
}

for dir in /proc/[0-9]*; do
  k=$(kind "${dir#/proc/}" 2> /dev/null) || continue
  [ -n "$k" ] || continue
  if [ "${1:-count}" = memory ]; then
    awk -v kind="$k" '/^Rss:/ {r=$2} /^Pss:/ {s=$2} /^Private_Clean:/ {pc=$2} /^Private_Dirty:/ {pd=$2} END {print kind, r, s, pc + pd}' "$dir/smaps_rollup" 2> /dev/null || true
  else
    echo "$k"
  fi
done
