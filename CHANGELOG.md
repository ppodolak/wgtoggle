# Changelog

## Unreleased

## 1.12.0 - 2026-11-27

### Changed
- Helper installation keeps a root-owned journal (`/var/db/wgtoggle-install.journal`). An install killed at any point, including a first install or during cleanup, is undone or finished correctly by the next run.
- Passwordless helper v6: status output is verified (record count, no duplicates, nothing after the end marker, no orphan peers). Anything off means "unknown".
- In passwordless mode the tunnel's real interface (from wg-quick's runtime file) decides its state; address matching is only used without the helper.
- `wgtoggle status --strict` uses one snapshot for both the output and the exit code.
- `wgtoggle profile` stops at the first failed stage and rolls back right away.

### Fixed
- Split-DNS markers written by 1.9/1.10 hooks (no tunnel name) were removed by `dns repair` even while their tunnel was running.

## 1.11.1 - 2026-11-27

### Added
- Notification at launch when the passwordless helper is older than the app needs. Click it to update (one password prompt).

## 1.11.0 - 2026-11-27

### Added
- `wgtoggle status --strict`: exit 4 if any tunnel's state can't be determined.
- An install that was interrupted (power loss, killed) is recovered automatically by the next one.

### Changed
- Split-DNS markers record the tunnel name as well as its `utun`, and are checked against wg-quick's runtime file. A reused `utun` after a reboot no longer keeps a dead tunnel's resolver.
- `wgtoggle profile` refuses to start when a tunnel's state is unknown, and verifies the rollback with the same rules.
- Passwordless helper v5: status output ends with a completeness marker; incomplete or garbled output means "unknown" instead of partial data.
- Rollback keeps restoring the remaining parts even if one step fails.

### Fixed
- Two configs with the same interface address could be mixed up; without the helper they now show "unknown".

## 1.10.0 - 2026-11-27

### Added
- `wgtoggle dns repair`, and automatic repair at launch in passwordless mode: resolvers left by a crashed tunnel or a reboot are rebuilt, restored or removed.

### Changed
- Root commands use system directories first in `PATH`, and `wg-quick` is always started by absolute path. A planted file in Homebrew's `bin` can't shadow `cp`, `install` or other system tools anymore.
- Helper installation is a full transaction: any failure (including explicit exits) restores the previous helper, sudo rule and migrated or overwritten configs; a failed first install leaves nothing behind.
- A failing passwordless helper makes tunnel state "unknown" instead of looking like everything is down.
- Passwordless helper v4 (`dns-repair`).

### Fixed
- The installer's post-install check never aborted: macOS's bash 3.2 ignores `set -e` for a failing `[[ ]]`.
- Profile verification could read cached state right after a change; the cache is now cleared after every connect/disconnect. Unknown tunnels make profile verification report "incomplete" (exit 4).

## 1.9.0 - 2026-11-27

### Added
- Keys are redacted from logs (file, unified log, Log Explorer exports).
- Helper installer rolls back to the previous helper and sudo rule if any step fails, and checks every migrated config byte for byte.
- `wgtoggle profile` reports whether the rollback worked (exit `1` restored, `3` rollback failed).

### Changed
- Split-DNS state moved to `/var/db/wgtoggle-dns` so it survives reboots. Configs converted by earlier versions keep working.
- A peer is flagged as soon as anything is sent to it without a fresh handshake (unreachable peers only send small handshake attempts).
- `wgtoggle routes` says it shows configured AllowedIPs.

### Fixed
- `wgtoggle down` skipped tunnels whose state was unknown.
- Peer monitoring kept data for tunnels that were down and peers that were removed.
- Routing-message parsing reads unaligned data safely and stops on malformed lengths.

## 1.8.0 - 2026-11-27

### Added
- Per-peer health for configs with several peers (passwordless mode): a peer that gets traffic but no handshake is shown in the menu and notified, even when other peers work. `wgtoggle status --json` lists peers.

### Changed
- Passwordless helper v3 (per-peer status). **Settings → Update Passwordless Helper…** appears if you use passwordless mode.
- `AppDelegate.swift` split into extensions: menu bar, tunnel actions, config editing, settings.

## 1.7.0 - 2026-11-27

### Added
- **Settings → Use Root-Owned wg-quick**: root-owned tool copies without passwordless mode. Password prompts stay; Homebrew's user-writable files are no longer run as root.
- `wgtoggle profile` switches under one lock, verifies the result and restores the previous tunnels if the switch fails.
- `wgtoggle conflicts` exits with `4` and names the tunnels it couldn't inspect instead of reporting success.
- IPv6-only tunnels are detected and monitored.

### Changed
- Shared split DNS keeps each tunnel's nameservers: when one tunnel disconnects, the resolver is rebuilt from a tunnel that's still running. A resolver file that existed before WGToggle is restored afterwards.
- A tunnel whose state can't be verified (unreadable config, no helper) is shown as "status unknown" instead of up.
- Version comparison handles prereleases (`1.7.0` is newer than `1.7.0-beta.2`).

### Fixed
- A scheduled automatic restart could reconnect a tunnel you had disconnected in the meantime.

## 1.6.0 - 2026-11-27

### Added
- Two tunnels can share a split-DNS domain: hooks written by WGToggle track which running tunnels use a resolver and only remove it when the last one disconnects. No more warning for configs that use them.
- Shell completion for zsh, bash and fish (commands, tunnel names, profiles), installed by the Homebrew cask.
- The app and `wgtoggle` no longer change tunnels at the same time (shared lock; the CLI waits, the app reports busy).
- `wgtoggle list --names` and `--profiles` for scripts and completion.

## 1.5.0 - 2026-11-27

### Added
- `wgtoggle routes`, `conflicts`, `dns` and `version`. Stable exit codes; JSON output now has a `version` field.
- Conflict checks also cover root-owned configs in passwordless mode (via a key-free `meta` helper command).
- Auto-restart backoff: 10 s, 20 s, 40 s, then a 15 minute pause, so an unreachable server doesn't cause endless reconnects.
- **Settings → Update Passwordless Helper…** when a newer helper is available.

### Changed
- Health check trusts a fresh handshake when one is known, so one-way traffic no longer looks stuck.
- Code split into `Core.swift`, `AppDelegate.swift` and a small `main.swift`.

### Fixed
- With root-owned configs, a tunnel whose `wireguard-go` had died could be shown as up as long as any other tunnel was running. Status is now checked per tunnel, and the helper skips stale name files.

## 1.4.0 - 2026-11-27

### Added
- `wgtoggle` command line tool (installed by the Homebrew cask).
- IPv6 overlap checks and warnings for `::/0`, invalid `AllowedIPs` entries, and split DNS domains shared by two tunnels.
- README screenshots, demo GIF and a `--demo` mode used to make them.

### Changed
- When passwordless mode is installed, password-prompted commands also use the root-owned tool copies instead of Homebrew's.
- Command output is marked private in the unified log.
- CI: read-only build job, separate release job holding write access and the tap token, actions pinned to commit SHAs, Dependabot for actions.

### Fixed
- Traffic counters resetting after a tunnel restart could trigger a false "stuck" warning.
- Log Explorer level filters were hard to read when enabled.

## 1.3.0 - 2026-11-26

### Added
- Live stats per tunnel: traffic, last handshake and IP. Hold ⌥ to copy the IP.
- Stuck tunnel detection (traffic out, nothing back) with a notification and optional automatic restart.
- Passwordless mode using a root-owned helper and a narrow sudoers rule.
- Split DNS conversion when importing a config with a global `DNS =` line.
- Auto-connect at launch, after wake, after network changes and when a tunnel drops.
- Profiles, tunnel editing, QR code import, global shortcut ⌃⌥⌘T.
- Update check against GitHub Releases.
- About window.
- `--diagnose` command line flag.
- Self-tests, run in CI.
- Homebrew cask: `brew install --cask ppodolak/tap/wgtoggle`.

### Fixed
- Connecting and disconnecting failed with "Authorization failed" in 1.2.0.
- Tunnels were shown as up after `wireguard-go` had exited.

## 1.2.0 - 2026-11-26

### Added
- Log Explorer window, notifications, connecting animation, Show in Dock, Buy Me a Coffee link.
- Hook approval, overlap and DNS warnings when adding tunnels.
- Import several configs, paste a config, drag files onto the app, remove tunnels.

### Known issues
- Connecting and disconnecting fail with "Authorization failed". Fixed in 1.3.0.
