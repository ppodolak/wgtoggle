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
    static let journal = "/var/db/wgtoggle-install.journal"

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
    check_conf() {
      [[ "$name" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ ]] || { echo "invalid tunnel name" >&2; exit 2; }
      conf="$DIR/$name.conf"
      [[ -f "$conf" && ! -L "$conf" ]] || { echo "no such tunnel: $conf" >&2; exit 2; }
      [[ "$(stat -f %u "$conf")" == 0 && "$(stat -f %u "$DIR")" == 0 ]] || { echo "$conf must be owned by root" >&2; exit 2; }
      [[ $(( 0$(stat -f %Lp "$conf") & 022 )) == 0 ]] || { echo "$conf is group/world writable" >&2; exit 2; }
    }
    case "$cmd" in
      version) echo 6 ;;
      dns-repair)
        \#(SplitDNS.repairScript()) ;;
      up|down)
        check_conf
        exec "$H/bash" "$H/wg-quick" "$cmd" "$conf" ;;
      meta)
        # Routing/DNS/hook lines for conflict checks. Never prints PrivateKey or PresharedKey.
        check_conf
        grep -iE '^[[:space:]]*(\[Interface\]|\[Peer\]|Address|AllowedIPs|DNS|PreUp|PostUp|PreDown|PostDown)[[:space:]]*(=|$)' "$conf" || true ;;
      status)
        # name iface latest-handshake rx tx   (no keys are printed)
        emitted=0
        for f in /var/run/wireguard/*.name; do
          [[ -e "$f" ]] || continue
          n=$(basename "$f" .name); i=$(cat "$f")
          [[ -S "/var/run/wireguard/$i.sock" ]] || continue   # stale name file: wireguard-go is gone
          hs=$("$H/wg" show "$i" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
          tr=$("$H/wg" show "$i" transfer 2>/dev/null | awk '{r+=$2; t+=$3} END {print r+0, t+0}')
          echo "$n $i ${hs:-0} ${tr:-0 0}"; emitted=$((emitted + 1))
          # one line per peer: peer NAME PUBLICKEY HANDSHAKE RX TX (public keys only; no `wg show dump`, it prints the private key)
          "$H/wg" show "$i" latest-handshakes 2>/dev/null | while read -r k t; do
            ptr=$("$H/wg" show "$i" transfer 2>/dev/null | awk -v k="$k" '$1 == k {print $2, $3}')
            echo "peer $n $k ${t:-0} ${ptr:-0 0}"
          done
        done
        echo "end $emitted" ;;   # completeness marker: number of tunnel lines above
      *) echo "usage: wgtoggle-helper up|down|meta NAME | status | dns-repair | version" >&2; exit 2 ;;
    esac
    """#

    /// Root installer: copies tools + their Homebrew dylibs into the helper dir, rewires library paths,
    /// writes the helper and a visudo-checked sudoers rule, and moves configs into /etc/wireguard.
    /// Root-owned tool copies exist (installed by passwordless mode or on their own).
    static var toolsInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: "\(dir)/wg-quick"), let a = try? fm.attributesOfItem(atPath: dir) else { return false }
        return (a[.ownerAccountID] as? Int) == 0
    }

    /// `sudoers: false` installs only the root-owned tool copies (password prompts stay).
    static func installer(user: String, moveFrom: [String], sudoers withRule: Bool = true) -> String {
        let moves = moveFrom.map { src -> String in
            let name = ((src as NSString).lastPathComponent as NSString).deletingPathExtension
            let dest = shellQuote("\(configDir)/\(name).conf")
            // record for rollback, copy, then verify byte for byte (set -e aborts and rolls back on mismatch)
            return """
                touchpath \(dest)
                install -o root -g wheel -m 600 \(shellQuote(src)) \(dest)
                cmp -s \(shellQuote(src)) \(dest)
                """
        }.joined(separator: "\n")
        return #"""
        #!/bin/bash
        set -euo pipefail
        H=\#(dir)
        NEW="$H.new.$$"
        S=\#(sudoers)
        # Transaction with a root-owned journal (survives kill/power loss). Every change is journaled BEFORE it's
        # made; "committed" is journaled before cleanup. On the next run: no "committed" = undo everything in it,
        # "committed" = just finish the cleanup.
        J=\#(journal)
        mkdir -p "$(dirname "$J")"
        undo() {   # replay the journal backwards
          set +e
          tail -r "$J" 2>/dev/null | while IFS=' ' read -r op path; do
            case "$op" in
              new) rm -rf "$path" ;;                                   # created by us: remove
              backup) if [[ -e "$path.wgtoggle-bak" ]]; then rm -rf "$path"; mv "$path.wgtoggle-bak" "$path"; fi ;;
            esac
          done
          rm -f "$J"
        }
        finish() {   # committed: drop the backups
          set +e
          while IFS=' ' read -r op path; do [[ "$op" == backup ]] && rm -rf "$path.wgtoggle-bak"; done < "$J"
          rm -f "$J"
        }
        if [[ -e "$J" ]]; then
          if grep -qx committed "$J"; then echo "finishing an earlier install" >&2; finish
          else echo "recovering interrupted install" >&2; undo; fi
        fi
        rm -rf "$H".new.*
        : > "$J"; chmod 600 "$J"
        # Journal a path, then back it up (or note it as new). Call BEFORE changing the path.
        touchpath() { if [[ -e "$1" ]]; then echo "backup $1" >> "$J"; rm -rf "$1.wgtoggle-bak"; cp -Rp "$1" "$1.wgtoggle-bak"; else echo "new $1" >> "$J"; fi; }
        COMMITTED=0
        trap 'rc=$?; if [[ $rc -ne 0 && $COMMITTED == 0 ]]; then echo "install failed, rolling back" >&2; undo; fi' EXIT
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
        touchpath "$H"; rm -rf "$H"; mv "$NEW" "$H"
        touchpath "$S"
        \#(withRule ? sudoersAndConfigs(user: user, moves: moves) : "rm -f \(sudoers)")
        # post-install checks: tools run, helper answers
        # explicit exits: /bin/bash 3.2 does not apply set -e to a failing [[ ]]
        "$H/bash" -c 'exit 0' || { echo "installed bash does not run" >&2; exit 1; }
        [[ "$("$H/wgtoggle-helper" version)" == \#(currentVersion) ]] || { echo "installed helper does not answer" >&2; exit 1; }
        echo committed >> "$J"; COMMITTED=1
        finish
        echo "helper installed"
        """#
    }

    static func sudoersAndConfigs(user: String, moves: String) -> String {
        #"""
        RULE=$(mktemp)
        echo "\#(user) ALL=(root) NOPASSWD: $H/wgtoggle-helper" > "$RULE"
        visudo -cf "$RULE" >/dev/null
        install -o root -g wheel -m 440 "$RULE" \#(sudoers); rm -f "$RULE"

        mkdir -p \#(configDir); chown root:wheel \#(configDir); chmod 755 \#(configDir)
        \#(moves)
        """#
    }

    /// One admin prompt. The script is staged in a root-only path and hash-checked before it runs,
    /// so a user process can't swap it between writing and execution.
    static func install(movingConfigs: [Tunnel], sudoers withRule: Bool = true) throws -> String {
        let user = NSUserName()
        guard user.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil else {
            throw NSError(domain: "WGToggle", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported user name"])
        }
        let text = installer(user: user, moveFrom: withRule ? movingConfigs.map(\.path) : [], sudoers: withRule)
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

    /// Bump when the helper script changes; older installs get an "update" prompt.
    static let currentVersion = 6

    private static var versionCache: Int?

    /// Asked once per process (and again after install/uninstall); status reads depend on it.
    static var installedVersion: Int {
        if let v = versionCache { return v }
        guard isInstalled else { return 0 }
        let v = Int((try? run(["version"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 1
        versionCache = v
        return v
    }

    static var needsUpdate: Bool { isInstalled && installedVersion < currentVersion }

    /// Config text without keys, for root-only configs (conflict checks). nil if unavailable.
    static func meta(_ name: String) -> String? {
        guard isInstalled, installedVersion >= 2 else { return nil }
        return try? run(["meta", name])
    }

    private static let lock = NSLock()
    private static var cache: (Date, [String: Status]?)?
    private static var lastFailed = false

    /// `status()` is a sudo call; `isUp` is asked many times per second while the menu is open.
    /// nil = the helper couldn't be asked (not the same as "no tunnels up").
    static func cachedStatus() -> [String: Status]? {
        lock.lock()
        let cached = cache
        lock.unlock()
        if let (at, s) = cached, Date().timeIntervalSince(at) < 2 { return s }
        // The main thread never waits for sudo once there's any answer: the stats queue refreshes every 5 s.
        if Thread.isMainThread, let (_, s) = cached { return s }
        let s = status()   // outside the lock: a slow helper call must not block other readers
        lock.lock(); cache = (Date(), s); lock.unlock()
        return s
    }

    /// Call after connecting/disconnecting so the next check reads fresh state.
    static func invalidateCache() { lock.lock(); cache = nil; versionCache = nil; lock.unlock() }

    static func uninstall() throws {
        try runAsAdmin("rm -f \(sudoers) && rm -rf \(shellQuote(dir))")
    }

    /// Runs the helper via `sudo -n` (never prompts). Returns combined output; throws on failure.
    @discardableResult
    /// Never blocks forever: a stuck `wg show` (e.g. a hung wireguard-go) would otherwise freeze the caller.
    /// up/down may legitimately take a while; status/meta/version should answer in well under a second.
    static func run(_ args: [String], timeout: TimeInterval? = nil, command: [String]? = nil) throws -> String {
        let limit = timeout ?? (["up", "down", "dns-repair"].contains(args.first ?? "") ? 60 : 5)
        let p = Process()
        let pipe = Pipe()
        let cmd = command ?? (["/usr/bin/sudo", "-n", path] + args)   // `command`: tests only
        p.executableURL = URL(fileURLWithPath: cmd[0])
        p.arguments = Array(cmd.dropFirst())
        p.standardOutput = pipe
        p.standardError = pipe
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        try p.run()
        var data = Data()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { data = pipe.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if exited.wait(timeout: .now() + limit) == .timedOut {
            p.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            throw NSError(domain: "WGToggle", code: -2, userInfo: [NSLocalizedDescriptionKey: "helper \(args.first ?? "") timed out after \(Int(limit))s"])
        }
        _ = readDone.wait(timeout: .now() + 2)
        let out = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "WGToggle", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: out.isEmpty ? "helper failed" : out])
        }
        return out
    }

    struct Peer { let key: String; let handshake: Date?; let rx: UInt64; let tx: UInt64 }
    struct Status { let iface: String; let handshake: Date?; let rx: UInt64; let tx: UInt64; var peers: [Peer] = [] }

    static func status() -> [String: Status]? {
        guard isInstalled else { return nil }
        do {
            let out = try run(["status"])
            guard let parsed = parseStatus(out, strict: installedVersion >= 6) else {
                if !lastFailed { Log.error("helper status incomplete, tunnel state unknown", detail: out); lastFailed = true }
                return nil
            }
            if lastFailed { Log.info("helper status works again"); lastFailed = false }
            return parsed
        } catch {
            if !lastFailed { Log.error("helper status failed, tunnel state unknown", detail: error.localizedDescription); lastFailed = true }
            return nil
        }
    }

    /// `name iface hs rx tx` per tunnel, then `peer name key hs rx tx` per peer (helper v3+).
    /// strict (helper v6+): every line parses, no duplicate tunnels, peers only for listed tunnels,
    /// and the last line is `end N` with N = number of tunnel lines. Anything else: nil (state unknown).
    static func parseStatus(_ out: String, strict: Bool = false) -> [String: Status]? {
        var r: [String: Status] = [:]
        var sawEnd = false
        let date = { (t: TimeInterval) in t > 0 ? Date(timeIntervalSince1970: t) : nil }
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            if strict && sawEnd { return nil }   // nothing may follow the end marker
            if f.count == 5, let hs = TimeInterval(f[2]), let rx = UInt64(f[3]), let tx = UInt64(f[4]) {
                if strict && r[f[0]] != nil { return nil }   // duplicate tunnel
                r[f[0]] = Status(iface: f[1], handshake: date(hs), rx: rx, tx: tx, peers: r[f[0]]?.peers ?? [])
            } else if f.count == 6, f[0] == "peer", let hs = TimeInterval(f[3]), let rx = UInt64(f[4]), let tx = UInt64(f[5]) {
                if strict && r[f[1]] == nil { return nil }   // peer of an unlisted tunnel
                r[f[1]]?.peers.append(Peer(key: f[2], handshake: date(hs), rx: rx, tx: tx))
            } else if f.count == 2, f[0] == "end", let n = Int(f[1]) {
                if strict && n != r.count { return nil }      // records missing or extra
                sawEnd = true
            } else if strict {
                return nil   // garbled line
            }
        }
        return strict && !sawEnd ? nil : r
    }
}
