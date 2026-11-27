# Changelog

## Unreleased

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
