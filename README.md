# ghsync

`ghsync.sh` discovers repositories owned by the authenticated GitHub user and
optionally selected organizations, then creates or updates pull mirrors on one
or more Gitea instances. It can also emit a repository manifest without Gitea,
or maintain bare local/remote clones.

Requirements: POSIX `/bin/sh`, `curl`, and `jq`. `git` is only needed for bare
replication and Git LFS. No Gitea source changes are required.

## Setup

1. Install `curl`, `jq`, and optionally `git` from your operating system package
   manager.
2. Copy `config.example` to `~/.config/ghsync/config`; edit it for your account
   and destinations. Configuration is shell syntax and must be trusted.
3. Store each credential as a single-line token file. Restrict access:

   ```sh
   mkdir -p ~/.config/ghsync
   chmod 700 ~/.config/ghsync
   printf '%s\n' 'YOUR_GITHUB_PAT' > ~/.config/ghsync/github.token
   chmod 600 ~/.config/ghsync/github.token
   ```

   Give the GitHub token the repository read access required for private repos.
   Each Gitea token needs repository creation, migration, and mirror sync access.
4. Run `sh ./ghsync.sh --dry-run --verbose`, then `sh ./ghsync.sh`.

Credentials are read from files. GitHub API authorization is passed to curl by
a mode-600 temporary curl config, not a process argument or log. The GitHub
credential is included in the TLS migration request to let Gitea fetch private
upstreams; use HTTPS endpoints and a narrowly scoped token.

## Configuration

The example file documents each setting. Define `ORG_COUNT` and numbered
`ORG_1`, `ORG_2` values to include organizations. Define numbered
`GITEA_N_URL`, `GITEA_N_USER`, and `GITEA_N_TOKEN_FILE` for each destination.
`INCLUDE_FORKS` and `INCLUDE_ARCHIVED` accept `yes` or `no`; `REPO_FILTER` is a
shell case pattern. `ACTIVE_INTERVAL` and `QUIET_INTERVAL` are seconds.
Set `SYSLOG=yes` to duplicate log messages to the host `logger` command when
available.

`--list jsonl` emits JSON Lines with IDs, privacy, timestamps and clone URLs;
`--list urls` emits HTTPS clone URLs. Listing requires only GitHub access and
does not create the state lock. Git clients can consume the URLs for bulk
cloning. `--dry-run` shows intended processing without API mutations.

For bare replication, set `BARE_COUNT` and `BARE_N_DESTINATIONS_FILE` to a
newline-delimited list of local directory roots or remote Git repository URLs.
Local directories receive `<repo>.git` bare clones; remote URLs receive mirror
pushes from a cached bare mirror. Bare mode requires Git; when `git lfs` is
installed, the utility fetches all LFS objects and pushes them to remote bare
destinations.

The state file under `STATE_DIR/state.tsv` stores GitHub IDs, names, last
processing times and pushed timestamps as tab-delimited records so renames and
upstream activity can be recognized. Failed repository operations are retried
on the next run. It is never used to delete a destination. Runs use an atomic directory lock;
cron should invoke the script directly and check its exit code. Exit codes are
0 success, 1 partial operation failure, 2 configuration/usage error, and 3
lock already held. `--verbose` writes progress to stderr. Cron/system syslog
integration can be supplied by the host scheduler's output redirection.

## Platforms

The script uses POSIX shell constructs, `mkdir` locking, and portable curl/jq
interfaces. Install `curl`, `jq`, and optionally `git` with the native package
manager:

* FreeBSD: `pkg install curl jq git`
* OpenBSD: `pkg_add curl jq git`
* NetBSD: install `curl`, `jq`, and `git` from pkgsrc (`pkgin install curl jq git`)
* macOS: Homebrew or MacPorts packages for `curl`, `jq`, and `git`
* Linux: the distribution's packages for `curl`, `jq`, and `git`
* Windows: run from Git Bash or Cygwin with curl, jq, and optional Git installed

The POSIX shell and mocked API suite can be run with `sh tests/mock-api.sh`.
`tests/integration-gitea.sh` runs a disposable-server smoke pass; verify the
created private mirror and its sync behavior in that Gitea instance. The initial FreeBSD, OpenBSD and Git Bash
portability run remains an operator/CI task; this workspace is Windows and
does not provide those operating systems.
