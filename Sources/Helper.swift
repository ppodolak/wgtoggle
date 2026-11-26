import AppKit
import CryptoKit

// MARK: - Passwordless mode
//
// Without a Developer ID we can't ship an SMAppService daemon, so passwordless mode uses sudo with a
// rule that allows exactly one root-owned script and nothing else:
//
//   /Library/PrivilegedHelperTools/wgtoggle/
//     wgtoggle-helper        root:wheel 0755  validates args, only runs root-owned /etc/wireguard/<name>.conf
//     wg-quick, wg, bash,    root-owned COPIES of the Homebrew tools (Homebrew files are user-writable,
//     wireguard-go, lib/     so running them as root without a password would hand root to any user process)
//   /etc/sudoers.d/wgtoggle  "<user> ALL=(root) NOPASSWD: /Library/PrivilegedHelperTools/wgtoggle/wgtoggle-helper"
//   /etc/wireguard/          root:wheel 0755, configs root:wheel 0600
//
// Up/down/status run without a password. Anything that changes configs or the helper still asks.

enum Helper {
    static let dir = "/Library/PrivilegedHelperTools/wgtoggle"
    static let path = "\(dir)/wgtoggle-helper"
    static let sudoers = "/etc/sudoers.d/wgtoggle"
    static let configDir = "/etc/wireguard"

    static var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path), fm.fileExists(atPath: sudoers),
              let a = try? fm.attributesOfItem(atPath: path) else { return false }
        return (a[.ownerAccountID] as? Int) == 0
    }

    /// The script sudo is allowed to run. Kept tiny and strict.
    static let script = #"""
    #!/bin/bash
    # wgtoggle-helper: the only command WGToggle may run as root without a password.
    set -euo pipefail
    H=/Library/PrivilegedHelperTools/wgtoggle
    export PATH="$H:/usr/bin:/bin:/usr/sbin:/sbin"
    DIR=/etc/wireguard
    cmd="${1:-}"; name="${2:-}"
    [[ $# -le 2 ]] || { echo "too many arguments" >&2; exit 2; }
    case "$cmd" in
      up|down)
        [[ "$name" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ ]] || { echo "invalid tunnel name" >&2; exit 2; }
        conf="$DIR/$name.conf"
        [[ -f "$conf" && ! -L "$conf" ]] || { echo "no such tunnel: $conf" >&2; exit 2; }
        [[ "$(stat -f %u "$conf")" == 0 && "$(stat -f %u "$DIR")" == 0 ]] || { echo "$conf must be owned by root" >&2; exit 2; }
        [[ $(( 0$(stat -f %Lp "$conf") & 022 )) == 0 ]] || { echo "$conf is group/world writable" >&2; exit 2; }
        exec "$H/bash" "$H/wg-quick" "$cmd" "$conf" ;;
      status)
        # name iface latest-handshake rx tx   (no keys are printed)
        for f in /var/run/wireguard/*.name; do
          [[ -e "$f" ]] || continue
          n=$(basename "$f" .name); i=$(cat "$f")
          hs=$("$H/wg" show "$i" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
          tr=$("$H/wg" show "$i" transfer 2>/dev/null | awk '{r+=$2; t+=$3} END {print r+0, t+0}')
          echo "$n $i ${hs:-0} ${tr:-0 0}"
        done ;;
      *) echo "usage: wgtoggle-helper up|down NAME | status" >&2; exit 2 ;;
    esac
    """#

    /// Root installer: copies tools + their Homebrew dylibs into the helper dir, rewires library paths,
    /// writes the helper and a visudo-checked sudoers rule, and moves configs into /etc/wireguard.
    static func installer(user: String, moveFrom: [String]) -> String {
        let moves = moveFrom.map { src -> String in
            let name = ((src as NSString).lastPathComponent as NSString).deletingPathExtension
            return "install -o root -g wheel -m 600 \(shellQuote(src)) \(shellQuote("\(configDir)/\(name).conf"))"
        }.joined(separator: "\n")
        return #"""
        #!/bin/bash
        set -euo pipefail
        H=\#(dir)
        NEW="$H.new.$$"
        BREW=""
        for p in /opt/homebrew /usr/local; do [[ -x "$p/bin/wg-quick" ]] && BREW="$p" && break; done
        [[ -n "$BREW" ]] || { echo "wg-quick not found" >&2; exit 1; }
        rm -rf "$NEW"; mkdir -p "$NEW/lib"
        for b in wg-quick wg wireguard-go bash; do
          src=$(/usr/bin/readlink -f "$BREW/bin/$b") || { echo "missing $b" >&2; exit 1; }
          cp "$src" "$NEW/$b"
        done
        # Bundle Homebrew dylibs (bash needs readline/ncurses/gettext) and point binaries at the copies.
        changed=1
        while [[ $changed == 1 ]]; do
          changed=0
          for f in "$NEW"/wg "$NEW"/wireguard-go "$NEW"/bash "$NEW"/lib/*.dylib; do
            [[ -f "$f" ]] || continue
            for dep in $(otool -L "$f" | awk 'NR>1 {print $1}' | grep -E '^(/opt/homebrew|/usr/local/(opt|Cellar|lib))' || true); do
              base=$(basename "$dep")
              if [[ ! -f "$NEW/lib/$base" ]]; then cp "$(/usr/bin/readlink -f "$dep")" "$NEW/lib/$base"; chmod u+w "$NEW/lib/$base"; changed=1; fi
              if [[ "$f" == "$NEW/lib/"* ]]; then
                install_name_tool -change "$dep" "@loader_path/$base" "$f" 2>/dev/null
              else
                install_name_tool -change "$dep" "@loader_path/lib/$base" "$f" 2>/dev/null
              fi
            done
          done
        done
        for l in "$NEW"/lib/*.dylib; do [[ -f "$l" ]] && install_name_tool -id "@loader_path/$(basename "$l")" "$l" 2>/dev/null; done
        for f in "$NEW"/wg "$NEW"/wireguard-go "$NEW"/bash "$NEW"/lib/*.dylib; do [[ -f "$f" ]] && codesign -f -s - "$f" 2>/dev/null; done
        "$NEW/bash" -c 'exit 0' || { echo "bundled bash does not run" >&2; exit 1; }
        sed -i '' "1s|.*|#!$H/bash|" "$NEW/wg-quick"
        cat > "$NEW/wgtoggle-helper" <<'HELPER'
        \#(script)
        HELPER
        chown -R root:wheel "$NEW"; chmod -R go-w "$NEW"; chmod 755 "$NEW" "$NEW"/wg-quick "$NEW"/wg "$NEW"/wireguard-go "$NEW"/bash "$NEW"/wgtoggle-helper
        mkdir -p /Library/PrivilegedHelperTools
        rm -rf "$H.old"; [[ -e "$H" ]] && mv "$H" "$H.old"; mv "$NEW" "$H"; rm -rf "$H.old"

        RULE=$(mktemp)
        echo "\#(user) ALL=(root) NOPASSWD: $H/wgtoggle-helper" > "$RULE"
        visudo -cf "$RULE" >/dev/null
        install -o root -g wheel -m 440 "$RULE" \#(sudoers); rm -f "$RULE"

        mkdir -p \#(configDir); chown root:wheel \#(configDir); chmod 755 \#(configDir)
        \#(moves)
        echo "helper installed"
        """#
    }

    /// One admin prompt. The script is staged in a root-only path and hash-checked before it runs,
    /// so a user process can't swap it between writing and execution.
    static func install(movingConfigs: [Tunnel]) throws -> String {
        let user = NSUserName()
        guard user.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil else {
            throw NSError(domain: "WGToggle", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported user name"])
        }
        let text = installer(user: user, moveFrom: movingConfigs.map(\.path))
        let hash = sha256(Data(text.utf8))
        let tmp = NSTemporaryDirectory() + "wgtoggle-install-\(UUID().uuidString).sh"
        try text.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let staged = "/var/root/wgtoggle-install.sh"
        let out = try runAsAdmin("""
            install -o root -g wheel -m 700 \(shellQuote(tmp)) \(staged) && \
            echo '\(hash)  \(staged)' | shasum -a 256 -c - >/dev/null && \
            /bin/bash \(staged); rc=$?; rm -f \(staged); exit $rc
            """)
        // Configs now live in /etc/wireguard; remove the user-writable copies so they can't shadow them.
        for t in movingConfigs { try? FileManager.default.removeItem(atPath: t.path) }
        return out
    }

    static func uninstall() throws {
        try runAsAdmin("rm -f \(sudoers) && rm -rf \(shellQuote(dir))")
    }

    /// Runs the helper via `sudo -n` (never prompts). Returns combined output; throws on failure.
    @discardableResult
    static func run(_ args: [String]) throws -> String {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", path] + args
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "WGToggle", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: out.isEmpty ? "helper failed" : out])
        }
        return out
    }

    struct Status { let iface: String; let handshake: Date?; let rx: UInt64; let tx: UInt64 }

    static func status() -> [String: Status] {
        guard isInstalled, let out = try? run(["status"]) else { return [:] }
        var r: [String: Status] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            guard f.count == 5, let hs = TimeInterval(f[2]), let rx = UInt64(f[3]), let tx = UInt64(f[4]) else { continue }
            r[f[0]] = Status(iface: f[1], handshake: hs > 0 ? Date(timeIntervalSince1970: hs) : nil, rx: rx, tx: tx)
        }
        return r
    }
}
