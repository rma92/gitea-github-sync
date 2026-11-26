#!/bin/sh
# Run against a disposable Gitea. Set GHSYNC_CONFIG to a dedicated test config.
set -eu
[ -n "${GHSYNC_CONFIG:-}" ] || { echo 'set GHSYNC_CONFIG to an isolated Gitea test config' >&2; exit 2; }
case ${GITEA_TEST_CONFIRM:-} in yes) ;; *) echo 'set GITEA_TEST_CONFIRM=yes to run against disposable Gitea' >&2; exit 2;; esac
SCRIPT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/ghsync.sh
sh "$SCRIPT" --dry-run --verbose
sh "$SCRIPT" --verbose
sh "$SCRIPT" --verbose
echo 'Gitea disposable-server smoke runs completed; verify the mirror and sync in Gitea.'
