Develop a lightweight GitHub-to-Gitea repository replication utility targeting FreeBSD, OpenBSD, and NetBSD.

**Requirements:**

- Implement in portable POSIX /bin/sh.
- Dependencies limited to curl, jq, and optionally git.
- No Python, Node.js, Bash, Docker, GNU-specific utilities, or external runtime frameworks.
- Discover all repositories owned by an authenticated GitHub user using the GitHub REST API.
- Support optional GitHub organizations, forks, archived repositories, and private repositories.
- Handle API pagination and rate limiting.
- Support multiple independently configured Gitea destination instances.
- Automatically create missing pull mirrors through the Gitea migration API.
- Preserve repository privacy and prevent accidental public exposure.
- Leave existing repositories untouched unless they are verified managed mirrors.
- Use GitHub pushed_at timestamps to dynamically assign configurable mirror intervals.
- Request immediate synchronization when upstream activity is detected.
- Identify renamed repositories using persistent GitHub repository IDs.
- Never automatically delete repositories, even when deleted upstream.
- Support Git LFS where available.
- Provide an optional bare Git repository replication mode for systems without Gitea.
- Store credentials in restricted-permission files and never expose tokens in logs or process arguments.
- Support dry-run, verbose logging, syslog, and meaningful exit codes.
- Prevent concurrent executions using portable locking.
- Operate reliably under cron.
- Continue processing other repositories and destinations after individual failures.
- Include a facility to generate a list of all the relevant github repos without necessarily using Gitea, which could be used to clone everything if sufficient authentication is provided (e.g. github-tool/gh, or a PAT).

Provide a sample configuration, README, BSD-specific installation instructions, mocked API tests, and integration tests against Gitea. Verify portability on FreeBSD, OpenBSD, and NetBSD rather than assuming Linux behavior.

Prefer simple, maintainable code over unnecessary abstractions. Do not modify Gitea itself.
