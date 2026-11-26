# ghsync

`ghsync.sh` discovers repositories owned by the authenticated GitHub user and
optionally selected organizations, then creates or updates pull mirrors on one
or more Gitea instances. It can also emit a repository manifest without Gitea,
or maintain bare local/remote clones.

Requirements: POSIX `/bin/sh`, `curl`, and `jq`. `git` is only needed for bare
replication and Git LFS. No Gitea source changes are required.

## FreeBSD setup

Run `ghsync.sh` on the FreeBSD host that runs Gitea. The Gitea URL
`http://127.0.0.1:3000` only works from that same host. Use a FreeBSD Unix login
for the script; it can be different from the Gitea web user `gitadmin`. Install
the tools and create private config directories:

```sh
pkg install curl jq
mkdir -p "$HOME/ghsync" "$HOME/.config/ghsync"
chmod 700 "$HOME/.config/ghsync"
```

Copy `ghsync.sh` into `$HOME/ghsync/` (for example, with `scp` from your
workstation).

### Create the GitHub PAT

On GitHub, create a fine-grained personal access token for your account. Grant
access to the repositories you want mirrored, with **Metadata: read** and
**Contents: read** permissions. Metadata read is needed to list repositories;
Contents read lets Gitea fetch private repository contents. If you include
organization repositories, choose the organization as a token resource owner
and satisfy any organization approval policy. See [GitHub's token
documentation](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
and [endpoint permission requirements](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens).

On FreeBSD, create a token file with mode 600. Using `vi` avoids putting the
token in shell history or a command argument:

```sh
umask 077
vi "$HOME/.config/ghsync/github.token"
chmod 600 "$HOME/.config/ghsync/github.token"
```

Paste the token as a single line, save, and exit.

### Create a Gitea PAT

Log in to Gitea as `gitadmin`, open **User Settings > Applications**, and create
an access token with the `write:repository` scope. This scope grants repository
read and write operations required for migration, editing, and mirror sync. See
[Gitea's access token documentation](https://docs.gitea.com/1.26/development/api-usage/).

Store it in a separate protected file:

```sh
vi "$HOME/.config/ghsync/gitea.token"
chmod 600 "$HOME/.config/ghsync/gitea.token"
```

Paste the Gitea token as a single line. This configuration uses plain HTTP on
loopback, so run the script on the FreeBSD host itself. If you later connect to
Gitea remotely, use an HTTPS endpoint.

### Create the config file

Paste this block on FreeBSD to generate a config. It limits the first run to one
test repository; replace the username and repository, then clear the filter
after confirming the mirror works:

```sh
cat > "$HOME/.config/ghsync/config" <<'EOF'
GITHUB_API=https://api.github.com
GITHUB_TOKEN_FILE=$HOME/.config/ghsync/github.token

ORG_COUNT=0
# To include an organization, set ORG_COUNT=1 and uncomment/set ORG_1:
# ORG_1=your-organization

INCLUDE_FORKS=yes
INCLUDE_ARCHIVED=yes
REPO_FILTER='YOUR_GITHUB_USERNAME/ONE_TEST_REPO'

ACTIVE_INTERVAL=3600
QUIET_INTERVAL=86400
SYSLOG=no
STATE_DIR=$HOME/.local/state/ghsync

GITEA_COUNT=1
GITEA_1_URL=http://127.0.0.1:3000
GITEA_1_USER=gitadmin
GITEA_1_TOKEN_FILE=$HOME/.config/ghsync/gitea.token

BARE_COUNT=0
EOF

chmod 600 "$HOME/.config/ghsync/config"
```

Check GitHub repository discovery, then preview the selected repository:

```sh
cd "$HOME/ghsync"
sh ./ghsync.sh -c "$HOME/.config/ghsync/config" --list jsonl
sh ./ghsync.sh -c "$HOME/.config/ghsync/config" --dry-run --verbose
```

The dry run checks GitHub discovery but does not call Gitea or validate its
token. Run once without `--dry-run` to create the mirror:

```sh
sh ./ghsync.sh -c "$HOME/.config/ghsync/config" --verbose
```

After confirming the test mirror, set `REPO_FILTER=''` in the config to include
all repositories available to the GitHub token. Forks and archived repositories
are included by the sample settings. Set `ORG_COUNT=1` and `ORG_1=your-org` if
you also want that organization's repositories.

Credentials are read from restricted-permission files. GitHub API
authorization is passed to curl through a private temporary curl config, not a
process argument or log. The GitHub PAT is sent in the Gitea migration API
request so Gitea can fetch private upstreams.

### Sample crontab

Run cron as the same FreeBSD Unix user that owns the config and token files. Edit
that user's crontab with `crontab -e` and add this example to run every 30
minutes:

```cron
PATH=/bin:/usr/bin:/usr/local/bin
*/30 * * * * /bin/sh /home/YOUR_FREEBSD_LOGIN/ghsync/ghsync.sh -c /home/YOUR_FREEBSD_LOGIN/.config/ghsync/config >> /home/YOUR_FREEBSD_LOGIN/ghsync.log 2>&1
```

Replace `YOUR_FREEBSD_LOGIN` with the Unix account's home directory name. The
script's directory lock prevents overlapping runs. Exit codes are 0 for
success, 1 for partial/operation failure, 2 for configuration or usage error,
and 3 when another run holds the lock.

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
