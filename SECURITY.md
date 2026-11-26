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
