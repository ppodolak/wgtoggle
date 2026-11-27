# Contributing

Thanks for wanting to help. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an [issue](https://github.com/ppodolak/wgtoggle/issues/new/choose) and include:

- macOS version and WGToggle version (menu → **About WGToggle**)
- what you did, what you expected, what happened
- the output of `--diagnose` (it prints no keys):

  ```bash
  /Applications/WGToggle.app/Contents/MacOS/WGToggle --diagnose
  ```

- relevant lines from the Log Explorer (menu → **Log Explorer…** → select → Copy)

Never paste a full `.conf` file. It contains your private key.

Security problems: please don't open a public issue, see [SECURITY.md](SECURITY.md).

## Development

Requirements: macOS 13+, Xcode Command Line Tools (`xcode-select --install`), Homebrew with `wireguard-tools`.

```bash
git clone https://github.com/ppodolak/wgtoggle.git
cd wgtoggle
./build.sh        # build/WGToggle.app and build/WGToggle.dmg
Tests/run.sh      # self-tests
open build/WGToggle.app
```

There's no Xcode project. The app is plain Swift compiled with `swiftc`:

| File | What's in it |
|---|---|
| `Sources/main.swift` | entry point: app or command line |
| `Sources/AppDelegate.swift` | app state, launch, icon |
| `Sources/AppDelegate+*.swift` | menu bar, tunnel actions, config editing, settings |
| `Sources/Core.swift` | tunnels, config parsing, conflicts, hook approval, logging, admin commands |
| `Sources/CLI.swift` | `wgtoggle` command line tool |
| `Sources/Helper.swift` | passwordless mode |
| `Sources/Stats.swift` | traffic counters, stuck detection |
| `Sources/Features.swift` | split DNS, profiles, auto-connect, updates, shortcut, QR |
| `Sources/LogExplorer.swift` | log window (SwiftUI) |
| `Sources/Notify.swift` | notifications |

## Pull requests

- Keep them focused. One change per PR is easier to review.
- Run `Tests/run.sh` and add a test when you change parsing, the helper or anything security related.
- Anything that runs as root (hooks, the helper script, the installer) gets extra scrutiny. Explain why the change is safe.
- No new dependencies unless there's a very good reason.
- Update the README if behaviour changes, and add a line to [CHANGELOG.md](CHANGELOG.md) under *Unreleased*.

## Releases

Maintainers tag a version (`git tag v1.4.0 && git push origin v1.4.0`). CI builds the DMG, publishes the release and updates the Homebrew cask.
