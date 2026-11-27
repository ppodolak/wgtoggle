import Foundation

// `wgtoggle` command line tool. Installed by the Homebrew cask as a wrapper that runs
// `WGToggle.app/Contents/MacOS/WGToggle cli <args>`, so settings and hook approvals are shared with the app.

enum CLI {
    static let usage = """
        usage: wgtoggle <command>

          list                  tunnels and whether they're up
          status [--json]       state, interface, IP, traffic, last handshake
          up NAME...            connect tunnels
          down NAME...          disconnect tunnels
          profile NAME          connect exactly the tunnels in a saved profile
          routes [--json]       networks each tunnel sends through the VPN
          conflicts             overlapping routes, default routes, shared DNS domains
          dns                   active split-DNS resolvers (/etc/resolver)
          version               app and wireguard-tools versions
          diagnose              status plus app settings (no keys are printed)

        Exit codes: 0 ok, 1 failed or problems found, 2 usage error,
                    4 incomplete (some configs couldn't be checked).
        JSON output has a "version" field; it changes only when fields are removed or renamed.

        Connecting asks for your password unless passwordless mode is on.
        Configs with hooks must be approved in the app first.
        """

    static func run(_ args: [String]) -> Int32 {
        let cmd = args.first ?? "help"
        let rest = Array(args.dropFirst())
        switch cmd {
        case "list":
            // --names / --profiles: plain lists for shell completion (no status lookups, fast)
            if rest.contains("--names") { listTunnels().forEach { print($0.name) }; return 0 }
            if rest.contains("--profiles") { Profiles.all.keys.sorted().forEach { print($0) }; return 0 }
            for t in listTunnels() { print("\(label(t.state))  \(t.name)") }
            return 0
        case "status":
            return status(json: rest.contains("--json"))
        case "up", "down":
            guard !rest.isEmpty else { fputs("wgtoggle \(cmd): name a tunnel\n", stderr); return 2 }
            return setState(rest, up: cmd == "up")
        case "profile":
            guard let name = rest.first, let members = Profiles.all[name] else {
                fputs("wgtoggle profile: unknown profile. Saved: \(Profiles.all.keys.sorted().joined(separator: ", "))\n", stderr)
                return 2
            }
            let missing = members.filter { m in !listTunnels().contains { $0.name == m } }
            guard missing.isEmpty else { fputs("wgtoggle profile: \(name) uses unknown tunnels: \(missing.joined(separator: ", "))\n", stderr); return 2 }
            return withLock {
                // One transition under one lock: down the extras, up the members, verify, else roll back.
                let before = Set(listTunnels().filter(\.isUp).map(\.name))
                let down = before.subtracting(members).sorted(), up = Set(members).subtracting(before).sorted()
                _ = apply(down, up: false)
                _ = apply(up, up: true)
                let after = Set(listTunnels().filter(\.isUp).map(\.name))
                if after == Set(members) { print("profile \(name) active"); return 0 }
                fputs("wgtoggle profile: switch to \(name) failed (up: \(after.sorted().joined(separator: ", "))), restoring previous tunnels\n", stderr)
                _ = apply(after.subtracting(before).sorted(), up: false)
                _ = apply(before.subtracting(after).sorted(), up: true)
                return 1
            }
        case "routes":
            let rows = listTunnels().map { t in (t, configText(t).map(allowedIPs) ?? []) }
            if rest.contains("--json") {
                return printJSON(["tunnels": rows.map { ["name": $0.0.name, "up": $0.0.isUp, "allowedIPs": $0.1] }])
            }
            for (t, r) in rows { print("\(t.isUp ? "up  " : "down")  \(t.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(r.isEmpty ? "(config not readable)" : r.joined(separator: ", "))") }
            return 0
        case "conflicts":
            let tunnels = listTunnels()
            let all = tunnels.compactMap { t in configText(t).map { (name: t.name, conf: $0) } }
            let skipped = tunnels.map(\.name).filter { n in !all.contains { $0.name == n } }
            var found: [String] = []
            for (i, t) in all.enumerated() {
                // Each pair once: compare with later tunnels only; per-tunnel checks run for every tunnel.
                found += conflicts(name: t.name, conf: t.conf, others: Array(all[(i + 1)...]))
            }
            found.forEach { print($0) }
            if !skipped.isEmpty {
                fputs("not checked (config not readable, turn on passwordless mode to inspect root-owned configs): \(skipped.joined(separator: ", "))\n", stderr)
            }
            if found.isEmpty && skipped.isEmpty { print("no conflicts between \(all.count) tunnels") }
            return !found.isEmpty ? 1 : skipped.isEmpty ? 0 : 4
        case "dns":
            let dir = "/etc/resolver"
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
            if files.isEmpty { print("no split-DNS resolvers in \(dir)") }
            for f in files {
                let ns = ((try? String(contentsOfFile: "\(dir)/\(f)", encoding: .utf8)) ?? "")
                    .split(separator: "\n").filter { $0.hasPrefix("nameserver") }.map { $0.dropFirst(11) }
                print("\(f.padding(toLength: 24, withPad: " ", startingAt: 0)) \(ns.joined(separator: ", "))")
            }
            return 0
        case "version":
            print("WGToggle \(Updates.current)")
            if let wg = findBinary("wg") {
                let p = Process(); let pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: wg); p.arguments = ["--version"]; p.standardOutput = pipe
                try? p.run(); p.waitUntilExit()
                print(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ").prefix(2).joined(separator: " "))
            } else { print("wireguard-tools not installed") }
            print("passwordless helper: \(Helper.isInstalled ? "v\(Helper.installedVersion)\(Helper.needsUpdate ? " (update available in the app)" : "")" : "not installed")")
            return 0
        case "diagnose":
            print("WGToggle \(Updates.current)  passwordless: \(Helper.isInstalled ? "on" : "off")  config dir: \(preferredConfigDir)")
            print("auto-connect: \(AutoConnect.tunnels.sorted().joined(separator: ", "))  profiles: \(Profiles.all.keys.sorted().joined(separator: ", "))")
            return status(json: false)
        default:
            print(usage)
            return cmd == "help" || cmd == "--help" || cmd == "-h" ? 0 : 2
        }
    }

    static func status(json: Bool) -> Int32 {
        let tunnels = listTunnels()
        let stats = HealthMonitor().sample(tunnels: tunnels).stats
        if json {
            let items: [[String: Any]] = tunnels.map { t in
                let s = stats[t.name]
                var d: [String: Any] = ["name": t.name, "up": t.isUp, "state": "\(t.state)", "path": t.path,
                                        "autoConnect": AutoConnect.tunnels.contains(t.name)]
                if let s {
                    d["interface"] = s.iface ?? NSNull()
                    d["address"] = s.address ?? NSNull()
                    d["rxBytes"] = s.rx
                    d["txBytes"] = s.tx
                    d["lastHandshake"] = s.handshake.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
                    d["peers"] = (Helper.cachedStatus()[t.name]?.peers ?? []).map { p in
                        ["publicKey": p.key, "rxBytes": p.rx, "txBytes": p.tx,
                         "lastHandshake": p.handshake.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()] as [String: Any]
                    }
                }
                return d
            }
            return printJSON(["tunnels": items])
        }
        for t in tunnels {
            var line = "\(label(t.state))  \(t.name.padding(toLength: 16, withPad: " ", startingAt: 0))"
            if let s = stats[t.name] {
                line += " \(s.iface ?? "-")  \(s.address ?? "-")  ↓\(formatBytes(s.rx)) ↑\(formatBytes(s.tx))"
                if let h = s.handshake { line += "  handshake \(formatAgo(h))" }
            }
            print(line)
        }
        return 0
    }

    static func label(_ s: Tunnel.State) -> String { s == .up ? "up  " : s == .down ? "down" : "?   " }

    /// Every JSON document carries a schema version.
    static func printJSON(_ body: [String: Any]) -> Int32 {
        var doc = body
        doc["version"] = 1
        let data = try! JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
        return 0
    }

    static func setState(_ names: [String], up: Bool) -> Int32 { withLock { apply(names, up: up) } }

    /// Runs `body` holding the app/CLI operation lock (waits up to 60 s for the app).
    static func withLock(_ body: () -> Int32) -> Int32 {
        var lock = OpLock.acquire(wait: 0)
        if lock == nil {
            fputs("waiting for another WGToggle operation to finish…\n", stderr)
            lock = OpLock.acquire(wait: 60)
        }
        guard let lock else { fputs("wgtoggle: still busy after 60s, giving up\n", stderr); return 1 }
        defer { OpLock.release(lock) }
        return body()
    }

    /// Connects/disconnects without taking the lock (callers hold it).
    static func apply(_ names: [String], up: Bool) -> Int32 {
        let all = listTunnels()
        let verb = up ? "up" : "down"
        var rc: Int32 = 0
        for name in names {
            guard let t = all.first(where: { $0.name == name }) else {
                fputs("wgtoggle: no tunnel named \(name)\n", stderr); rc = 2; continue
            }
            if t.isUp == up { print("\(name) is already \(up ? "up" : "down")"); continue }
            // Same rule as the app: hooks run as root, so they must have been approved.
            if let data = FileManager.default.contents(atPath: t.path),
               !hookLines(String(decoding: data, as: UTF8.self)).isEmpty, !HookApproval.isApproved(data) {
                fputs("wgtoggle: \(name) has PostUp/PreUp hooks that aren't approved. Connect it once from the app to review them.\n", stderr)
                rc = 1; continue
            }
            Log.info("cli: wg-quick \(verb) \(name)")
            let ok: Bool
            if Helper.isInstalled && t.path.hasPrefix(Helper.configDir + "/") {
                do { print(try Helper.run([verb, name]), terminator: ""); ok = true }
                catch { fputs("\(error.localizedDescription)\n", stderr); ok = false }
            } else {
                ok = sudoWgQuick(verb, t.path)
            }
            if !ok { rc = 1; Log.error("cli: wg-quick \(verb) \(name) failed") }
        }
        return rc
    }

    /// Runs Homebrew's wg-quick through sudo in the user's terminal (sudo asks for the password there).
    static func sudoWgQuick(_ verb: String, _ path: String) -> Bool {
        let tools = Helper.toolsInstalled ? Helper.dir : (findBinary("wg-quick") as NSString?)?.deletingLastPathComponent
        guard let tools, let bash = Helper.toolsInstalled ? "\(Helper.dir)/bash" : findBinary("bash") else {
            fputs("wgtoggle: wg-quick not found. brew install wireguard-tools\n", stderr)
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // wg-quick needs bash 4+ and finds wg/wireguard-go via PATH, which sudo resets.
        p.arguments = ["/usr/bin/env", "PATH=\(tools):/usr/bin:/bin:/usr/sbin:/sbin", bash, "\(tools)/wg-quick", verb, path]
        do { try p.run() } catch { fputs("\(error.localizedDescription)\n", stderr); return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
