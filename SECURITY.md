# Security policy

WGToggle runs `wg-quick` as root, and passwordless mode installs a sudo rule, so security reports are taken seriously.

## Reporting a vulnerability

Please **don't** open a public issue. Instead:

- use [GitHub private vulnerability reporting](https://github.com/ppodolak/wgtoggle/security/advisories/new), or
- email p.podolak@gmail.com with "WGToggle security" in the subject.

Include the version, steps to reproduce and what an attacker could gain. You'll get a reply within a few days. Once a fix is released you'll be credited in the release notes unless you'd rather not be.

## Supported versions

Only the latest release gets fixes. Update with `brew upgrade --cask wgtoggle` or from [Releases](https://github.com/ppodolak/wgtoggle/releases/latest).

## Scope

Especially interesting:

- running code as root without the user's approval (hooks, the helper script, the installer, the sudoers rule)
- bypassing hook approval or the helper's checks
- leaking private keys (files, logs, exports, diagnostics)

How the app protects against these, and what it can't protect against, is described in the [README](README.md#security).

## Threat model

**What WGToggle protects:** your WireGuard private keys, and root on your Mac. It runs `wg-quick` as root and, in passwordless mode, installs a sudo rule.

**Trust boundary: your macOS user account.** Anything running as you can already read your files, change Homebrew, change `WGToggle.app` itself, and wait for your next password prompt. WGToggle can't defend against that, and doesn't claim to. It does make sure that such code can't get root *without* you: no prompt is skipped, and nothing it can change is ever run as root without your password.

| Asset / path | How it's protected |
|---|---|
| Root via passwordless mode | sudo allows exactly one root-owned script; it accepts only `up`/`down`/`meta`/`status`/`dns-repair`/`version`, validates names, and only runs root-owned configs in `/etc/wireguard` |
| Root via the tools wg-quick runs | system directories first in `PATH`; root-owned copies of `wg-quick`, `wg`, `wireguard-go`, `bash` and its libraries (passwordless mode or **Use Root-Owned wg-quick**) |
| Root via config hooks (`PostUp`…) | shown and approved per config hash before they run; configs in `/etc/wireguard` are root-owned |
| Private keys | configs `0600`; keys redacted from logs, exports and privileged job output before it reaches disk; `meta` never prints key lines |
| Privileged job output | root-owned `0711` directory with an unguessable `0600` output file handed to you only when complete; removed a minute later |
| Overlapping root changes | one system-wide lock (`/var/run/wgtoggle-root.lock`) for every privileged job, helper `up`/`down` and DNS repair; the app refuses new admin work while a timed-out job still runs |
| Broken installs | root-owned journal, crash-safe backups (copied, verified, then published), rollback or completion on the next run |

**Known limits:**
- **Dependency provenance.** The root-owned tool copies come from your Homebrew install at the time you install them. WGToggle can't independently verify those files, because anything running as you could also alter Homebrew or WGToggle. Install passwordless mode right after `brew install`/`brew upgrade wireguard-tools` from a trusted network.
- **Not notarized.** Releases are ad-hoc signed. Each release has a SHA-256 file and a GitHub build provenance attestation (`gh attestation verify WGToggle-x.y.z.dmg --repo ppodolak/wgtoggle`), which ties the DMG to the public CI run that built it.
- **Hook approvals live in your user's preferences.** Code running as you can pre-approve hooks; this only matters for configs your user can write (not for root-owned ones in passwordless mode).
