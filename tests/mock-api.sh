#!/bin/sh
# Local API-boundary checks using mock curl/jq responses; no network required.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP=${TMPDIR:-/tmp}/ghsync-test.$$
trap 'rm -rf "$TMP"' 0 HUP INT TERM
mkdir -p "$TMP/bin" "$TMP/home/.config/ghsync" "$TMP/state"
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
out= code= url= method=GET datafile=
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2;;
    -w) code=1; shift 2;;
    -X) method=$2; shift 2;;
    --data-binary) datafile=${2#@}; shift 2;;
    http*) url=$1; shift;;
    *) shift;;
  esac
done
case $url in
  */api/v1/repos/migrate)
    cp "$datafile" "$MOCK_MIGRATION"
    : > "$MOCK_CREATED"
    : > "$out"; printf 201; exit 0
    ;;
  */api/v1/repos/mirrorbot/*/mirror-sync)
    : > "$MOCK_SYNC"
    : > "$out"; printf 204; exit 0
    ;;
  */api/v1/repos/mirrorbot/*)
    if [ -f "$MOCK_CREATED" ]; then printf '{"mirror":true}' > "$out"; printf 200
    else : > "$out"; printf 404; fi
    exit 0
    ;;
esac
case $url in
  *page=1)
    if [ ! -f "$MOCK_STATE" ]; then : > "$MOCK_STATE"; : > "$out"; printf 429; exit 0; fi
    first=1 last=100
    ;;
  *page=2) first=101; last=101 ;;
  *page=*) : > "$out"; printf 200; exit 0 ;;
  *) : > "$out"; printf 500; exit 0 ;;
esac
{
  printf '['
  i=$first
  while [ "$i" -le "$last" ]; do
    [ "$i" -eq "$first" ] || printf ','
    id=1; [ "$i" -eq 101 ] && id=2
    private=false; [ "$id" -eq 1 ] && private=true
    pushed=2026-01-01T00:00:00Z
    [ "${MOCK_ACTIVITY:-old}" = changed ] && pushed=2026-11-26T00:00:00Z
    printf '{"id":%s,"name":"repo-%s","full_name":"alice/repo-%s","private":%s,"fork":false,"archived":false,"pushed_at":"%s","clone_url":"https://github.com/alice/repo-%s.git","ssh_url":"git@github.com:alice/repo-%s.git","html_url":"https://github.com/alice/repo-%s","owner":{"login":"alice"}}' "$id" "$id" "$id" "$private" "$pushed" "$id" "$id" "$id"
    i=$((i + 1))
  done
  printf ']'
} > "$out"
[ -n "$code" ] && printf 200 || :
EOF
chmod +x "$TMP/bin/curl"
printf 'token\n' > "$TMP/home/.config/ghsync/github.token"
printf 'gitea-token\n' > "$TMP/home/.config/ghsync/gitea.token"
cat > "$TMP/config" <<EOF
GITHUB_TOKEN_FILE=$TMP/home/.config/ghsync/github.token
GITHUB_API=https://mock.invalid
ORG_COUNT=0
GITEA_COUNT=0
STATE_DIR=$TMP/state
EOF
MOCK_STATE="$TMP/requests" PATH="$TMP/bin:$PATH" HOME="$TMP/home" "$ROOT/ghsync.sh" -c "$TMP/config" --list jsonl > "$TMP/result"
[ "$(wc -l < "$TMP/result" | tr -d ' ')" -eq 2 ]
grep '"id":1' "$TMP/result" | grep '"private":true' >/dev/null
cat "$TMP/config" > "$TMP/filter-config"
printf 'REPO_FILTER=alice/repo-2\n' >> "$TMP/filter-config"
MOCK_STATE="$TMP/requests" PATH="$TMP/bin:$PATH" HOME="$TMP/home" "$ROOT/ghsync.sh" -c "$TMP/filter-config" --list urls > "$TMP/urls"
[ "$(wc -l < "$TMP/urls" | tr -d ' ')" -eq 1 ]
grep 'repo-2.git' "$TMP/urls" >/dev/null
mkdir "$TMP/state/lock"
if MOCK_STATE="$TMP/requests" PATH="$TMP/bin:$PATH" HOME="$TMP/home" "$ROOT/ghsync.sh" -c "$TMP/config"; then
  echo 'lock check failed' >&2; exit 1
else
  [ "$?" -eq 3 ]
fi
rmdir "$TMP/state/lock"
echo 'mock API pagination, retry, filtering, privacy and lock checks passed'

cat "$TMP/config" > "$TMP/mirror-config"
cat >> "$TMP/mirror-config" <<EOF
REPO_FILTER=alice/repo-1
GITEA_COUNT=1
GITEA_1_URL=https://gitea.mock
GITEA_1_USER=mirrorbot
GITEA_1_TOKEN_FILE=$TMP/home/.config/ghsync/gitea.token
EOF
MOCK_STATE="$TMP/requests" MOCK_CREATED="$TMP/created" MOCK_MIGRATION="$TMP/migration.json" MOCK_SYNC="$TMP/sync" MOCK_ACTIVITY=old PATH="$TMP/bin:$PATH" HOME="$TMP/home" "$ROOT/ghsync.sh" -c "$TMP/mirror-config"
grep '"private": true' "$TMP/migration.json" >/dev/null
MOCK_STATE="$TMP/requests" MOCK_CREATED="$TMP/created" MOCK_MIGRATION="$TMP/migration.json" MOCK_SYNC="$TMP/sync" MOCK_ACTIVITY=changed PATH="$TMP/bin:$PATH" HOME="$TMP/home" "$ROOT/ghsync.sh" -c "$TMP/mirror-config"
[ -f "$TMP/sync" ]
echo 'mock Gitea migration privacy and activity sync checks passed'
