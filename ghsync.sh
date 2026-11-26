#!/bin/sh
# GitHub to Gitea replication utility. Configuration is a trusted shell file.
set -u
VERSION=1
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG=${GHSYNC_CONFIG:-${HOME:-.}/.config/ghsync/config}
MODE=sync DRY_RUN=0 VERBOSE=0 FORMAT=jsonl

usage() {
  cat <<'EOF'
Usage: ghsync.sh [-c config] [--dry-run] [--verbose] [--list jsonl|urls]
Exit codes: 0 success, 1 partial/operation failure, 2 configuration or usage error, 3 lock busy.
EOF
}
while [ $# -gt 0 ]; do
  case $1 in
    -c|--config) [ $# -ge 2 ] || { usage >&2; exit 2; }; CONFIG=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --list) [ $# -ge 2 ] || { usage >&2; exit 2; }; MODE=list; FORMAT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[ -r "$CONFIG" ] || { echo "Cannot read config: $CONFIG" >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONFIG"
: "${GITHUB_TOKEN_FILE:=}"
: "${GITHUB_API:=https://api.github.com}"
: "${GITEA_COUNT:=0}"
: "${ORG_COUNT:=0}"
: "${INCLUDE_FORKS:=yes}" "${INCLUDE_ARCHIVED:=yes}"
: "${ACTIVE_INTERVAL:=3600}" "${QUIET_INTERVAL:=86400}"
: "${STATE_DIR:=${HOME:-.}/.local/state/ghsync}"
: "${LOCK_DIR:=$STATE_DIR/lock}"
: "${REPO_FILTER:=}"
: "${BARE_COUNT:=0}"
: "${SYSLOG:=no}"

log() { printf '%s\n' "ghsync: $*" >&2; [ "$SYSLOG" = yes ] && command -v logger >/dev/null 2>&1 && logger -t ghsync "$*"; return 0; }
vlog() { [ "$VERBOSE" -eq 1 ] && log "$*"; return 0; }
fail() { log "$*"; exit 2; }
command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required'
[ -n "$GITHUB_TOKEN_FILE" ] && [ -r "$GITHUB_TOKEN_FILE" ] || fail 'GITHUB_TOKEN_FILE must name a readable token file'
umask 077
mkdir -p "$STATE_DIR" || fail 'cannot create state directory'
if [ "$MODE" != list ]; then
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then log "another run holds $LOCK_DIR"; exit 3; fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || :' 0 HUP INT TERM
fi
TMP=${TMPDIR:-/tmp}/ghsync.$$.tmp
trap 'rm -f "$TMP" "$TMP.auth" "$TMP.body" "$TMP.payload" "$TMP.repos" "$TMP.filtered" "$TMP.state"; if [ "$MODE" != list ]; then rmdir "$LOCK_DIR" 2>/dev/null || :; fi' 0 HUP INT TERM

for number in "$ORG_COUNT" "$GITEA_COUNT" "$BARE_COUNT" "$ACTIVE_INTERVAL" "$QUIET_INTERVAL"; do
  case $number in ''|*[!0-9]*) fail 'counts and intervals must be non-negative integers';; esac
done

# Token is placed in a mode-600 curl config, never a command-line argument.
auth_config() {
  token=$(cat "$1" 2>/dev/null) || return 1
  case $token in *'"'*|*'\'*|*"
"*) return 1;; esac
  printf 'header = "Authorization: token %s"\n' "$token" > "$TMP.auth"
  unset token
}
api_get() {
  url=$1 auth=$2
  auth_config "$auth" || return 1
  attempt=1
  while [ "$attempt" -le 5 ]; do
    code=$(curl -sS --config "$TMP.auth" -H 'Accept: application/vnd.github+json' -o "$TMP.body" -w '%{http_code}' "$url") || code=000
    case $code in
      200) cat "$TMP.body"; return 0 ;;
      403|429) log "API rate limited ($code), retry $attempt/5"; sleep "$attempt" ;;
      5??|000) log "transient API failure ($code), retry $attempt/5"; sleep "$attempt" ;;
      *) log "API request failed ($code)"; return 1 ;;
    esac
    attempt=$((attempt + 1))
  done
  return 1
}
gitea_call() {
  base=$1 tokenfile=$2 method=$3 path=$4 data=${5-}
  auth_config "$tokenfile" || return 1
  set -- -sS --retry 2 --config "$TMP.auth" -H 'Accept: application/json' -H 'Content-Type: application/json' -X "$method"
  if [ -n "$data" ]; then printf '%s' "$data" > "$TMP.payload" || return 1; set -- "$@" --data-binary "@$TMP.payload"; fi
  code=$(curl "$@" -o "$TMP.body" -w '%{http_code}' "${base%/}/api/v1$path") || return 1
  case $code in 200|201|202|204) cat "$TMP.body" 2>/dev/null; return 0;; *) log "Gitea $method $path failed ($code)"; return 1;; esac
}
lfs_sync() {
  repository=$1 destination=${2-}
  git -C "$repository" lfs version >/dev/null 2>&1 || return 0
  git -C "$repository" lfs fetch --all origin >/dev/null 2>&1 || return 1
  [ -z "$destination" ] || git -C "$repository" lfs push --all "$destination" >/dev/null 2>&1
}

# Build repository JSON array from every page. Organization repos are added separately.
REPOS=$TMP.repos
: > "$REPOS"
fetch_pages() {
  endpoint=$1 page=1
  while :; do
    case $endpoint in *\?*) separator='&';; *) separator='?';; esac
    url="${GITHUB_API%/}/$endpoint${separator}per_page=100&page=$page"
    if ! api_get "$url" "$GITHUB_TOKEN_FILE" > "$TMP"; then return 1; fi
    jq -c '.[]' "$TMP" >> "$REPOS" || return 1
    n=$(jq 'length' "$TMP") || return 1
    [ "$n" -lt 100 ] && break
    page=$((page + 1))
  done
}
fetch_pages 'user/repos?visibility=all&affiliation=owner&sort=full_name' || fail 'could not enumerate GitHub repositories'
discovery_status=0
i=1
while [ "$i" -le "$ORG_COUNT" ]; do
  eval 'org=${ORG_'"$i"'}'
  fetch_pages "orgs/$org/repos?type=all&sort=full_name" || { log "could not enumerate organization $org"; discovery_status=1; }
  i=$((i + 1))
done
jq -cs 'unique_by(.id)[]' "$REPOS" > "$TMP" || fail 'invalid repository data from GitHub'
mv "$TMP" "$REPOS" || fail 'cannot prepare repository list'

# Filter and emit manifest; managed state maps immutable GitHub IDs to destination names.
STATE=$STATE_DIR/state.tsv
[ -f "$STATE" ] || : > "$STATE"
filtered=$TMP.filtered
: > "$filtered"
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  fork=$(printf '%s' "$repo" | jq -r '.fork') archived=$(printf '%s' "$repo" | jq -r '.archived')
  [ "$INCLUDE_FORKS" = yes ] || [ "$fork" != true ] || continue
  [ "$INCLUDE_ARCHIVED" = yes ] || [ "$archived" != true ] || continue
  full=$(printf '%s' "$repo" | jq -r '.full_name')
  case $full in $REPO_FILTER) ;; *) [ -z "$REPO_FILTER" ] || continue;; esac
  printf '%s\n' "$repo" >> "$filtered"
done < "$REPOS"

if [ "$MODE" = list ]; then
  case $FORMAT in
    jsonl) while IFS= read -r repo; do printf '%s\n' "$(printf '%s' "$repo" | jq -c '{id,name,full_name,private,fork,archived,pushed_at,clone_url,ssh_url,html_url}')"; done < "$filtered" ;;
    urls) while IFS= read -r repo; do printf '%s\n' "$(printf '%s' "$repo" | jq -r '.clone_url')"; done < "$filtered" ;;
    *) fail 'list format must be jsonl or urls' ;;
  esac
  exit 0
fi

status=$discovery_status
now=$(date +%s)
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  id=$(printf '%s' "$repo" | jq -r '.id') full=$(printf '%s' "$repo" | jq -r '.full_name')
  owner=$(printf '%s' "$repo" | jq -r '.owner.login') name=$(printf '%s' "$repo" | jq -r '.name')
  private=$(printf '%s' "$repo" | jq -r '.private') pushed=$(printf '%s' "$repo" | jq -r '.pushed_at // empty')
  [ "$private" = true ] && is_private=true || is_private=false
  old=$(awk -F '\t' -v id="$id" '$1==id {print $2; exit}' "$STATE")
  old=${old:-$full}
  oldpushed=$(awk -F '\t' -v id="$id" '$1==id {print $4; exit}' "$STATE")
  pushed_epoch=0
  if [ -n "$pushed" ]; then pushed_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$pushed" +%s 2>/dev/null || date -d "$pushed" +%s 2>/dev/null || printf 0); fi
  age=$((now - pushed_epoch)); interval=$QUIET_INTERVAL
  [ "$age" -le "$ACTIVE_INTERVAL" ] && interval=$ACTIVE_INTERVAL
  last=$(awk -F '\t' -v id="$id" '$1==id {print $3; exit}' "$STATE")
  due=0; [ -z "$last" ] && due=1
  [ $((now - ${last:-0})) -ge "$interval" ] && due=1
  [ -n "$oldpushed" ] && [ "$oldpushed" != "$pushed" ] && due=1
  if [ "$old" != "$full" ]; then vlog "GitHub repository $id renamed: $old -> $full"; fi
  if [ "$DRY_RUN" -eq 1 ]; then log "would process $full"; continue; fi
  repo_status=0
  n=1
  while [ "$n" -le "$GITEA_COUNT" ]; do
    eval 'base=${GITEA_'"$n"'_URL}; user=${GITEA_'"$n"'_USER}; tok=${GITEA_'"$n"'_TOKEN_FILE}'
    encoded=$(printf '%s' "$name" | jq -sRr @uri)
    lookup=$name
    detail=$(gitea_call "$base" "$tok" GET "/repos/$user/$encoded" 2>/dev/null) || detail=
    if [ -z "$detail" ] && [ "$old" != "$full" ]; then
      lookup=${old#*/}; old_encoded=$(printf '%s' "$lookup" | jq -sRr @uri)
      detail=$(gitea_call "$base" "$tok" GET "/repos/$user/$old_encoded" 2>/dev/null) || detail=
    fi
    if [ -z "$detail" ]; then
      body=$(jq -cn --arg clone "$(printf '%s' "$repo" | jq -r '.clone_url')" --arg name "$name" --arg owner "$user" --argjson priv "$is_private" '{clone_addr:$clone,repo_name:$name,repo_owner:$owner,service:"github",mirror:true,private:$priv,auth_token:""}')
      # Migration auth is GitHub token; include it only in request body over TLS.
      body=$(printf '%s' "$body" | jq --rawfile t "$GITHUB_TOKEN_FILE" '.auth_token=($t|sub("\\n$";""))')
      [ "$is_private" = true ] && body=$(printf '%s' "$body" | jq '.private=true')
      if [ "$is_private" = false ]; then body=$(printf '%s' "$body" | jq '.private=false'); fi
      vlog "creating pull mirror $base/$user/$name"
      gitea_call "$base" "$tok" POST /repos/migrate "$body" >/dev/null || { status=1; repo_status=1; }
    else
      managed=$(printf '%s' "$detail" | jq -r '.mirror // false')
      [ "$managed" = true ] || { log "leaving unmanaged Gitea repo $user/$name untouched"; repo_status=1; status=1; n=$((n+1)); continue; }
      managed_private=$(printf '%s' "$detail" | jq -r '.private // false')
      if [ "$old" != "$full" ] || { [ "$is_private" = true ] && [ "$managed_private" != true ]; }; then
        current_encoded=$(printf '%s' "$lookup" | jq -sRr @uri)
        edit=$(jq -cn --arg name "$name" --argjson private "$is_private" '{name:$name} + (if $private then {private:true} else {} end)')
        gitea_call "$base" "$tok" PATCH "/repos/$user/$current_encoded" "$edit" >/dev/null || { status=1; repo_status=1; }
      fi
      if [ "$due" -eq 1 ]; then
        gitea_call "$base" "$tok" POST "/repos/$user/$encoded/mirror-sync" '' >/dev/null || { status=1; repo_status=1; }
      fi
    fi
    n=$((n + 1))
  done
  # Optional bare destinations are newline-separated paths/URLs in BARE_DESTINATIONS file.
  if [ "$BARE_COUNT" -gt 0 ]; then
    command -v git >/dev/null 2>&1 || { log 'git required for bare destinations'; status=1; repo_status=1; }
    if command -v git >/dev/null 2>&1; then
      n=1; while [ "$n" -le "$BARE_COUNT" ]; do
        eval 'destfile=${BARE_'"$n"'_DESTINATIONS_FILE}'
        while IFS= read -r dest; do
          [ -n "$dest" ] || continue
          case $dest in
            *://*|*@*:*)
              target=$STATE_DIR/bare-$id.git
              if [ ! -d "$target" ]; then
                [ "$DRY_RUN" -eq 1 ] || git clone --mirror "$(printf '%s' "$repo" | jq -r '.clone_url')" "$target" >/dev/null 2>&1 || { status=1; repo_status=1; }
              elif [ "$DRY_RUN" -eq 0 ]; then git -C "$target" fetch --prune origin >/dev/null 2>&1 || { status=1; repo_status=1; }; fi
              [ "$DRY_RUN" -eq 1 ] || git -C "$target" push --mirror "$dest" >/dev/null 2>&1 || { status=1; repo_status=1; }
              [ "$DRY_RUN" -eq 1 ] || lfs_sync "$target" "$dest" || { status=1; repo_status=1; }
              ;;
            *)
              target=${dest%/}/$name.git
              if [ ! -d "$target" ]; then [ "$DRY_RUN" -eq 1 ] || git clone --mirror "$(printf '%s' "$repo" | jq -r '.clone_url')" "$target" >/dev/null 2>&1 || { status=1; repo_status=1; }
              elif [ "$DRY_RUN" -eq 0 ]; then git -C "$target" fetch --prune origin >/dev/null 2>&1 || { status=1; repo_status=1; }; fi
              [ "$DRY_RUN" -eq 1 ] || lfs_sync "$target" || { status=1; repo_status=1; }
              ;;
          esac
        done < "$destfile"
        n=$((n+1))
      done
    fi
  fi
  # Persist GitHub ID, canonical name, processing time, and pushed_at for activity detection.
  if [ "$repo_status" -eq 0 ]; then
    awk -F '\t' -v id="$id" '$1!=id' "$STATE" > "$TMP.state"
    printf '%s\t%s\t%s\t%s\n' "$id" "$full" "$now" "$pushed" >> "$TMP.state"
    mv "$TMP.state" "$STATE"
  fi
done < "$filtered"
exit "$status"
