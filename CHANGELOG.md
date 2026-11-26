# Changelog

## Unreleased

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
