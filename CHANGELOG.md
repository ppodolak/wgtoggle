# Changelog

## Unreleased

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
