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
          diagnose              status plus app settings (no keys are printed)

        Connecting asks for your password unless passwordless mode is on.
        Configs with hooks must be approved in the app first.
        """

    static func run(_ args: [String]) -> Int32 {
        let cmd = args.first ?? "help"
        let rest = Array(args.dropFirst())
        switch cmd {
        case "list":
            for t in listTunnels() { print("\(t.isUp ? "up  " : "down")  \(t.name)") }
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
            let tunnels = listTunnels()
            let down = tunnels.filter { $0.isUp && !members.contains($0.name) }.map(\.name)
            let up = tunnels.filter { !$0.isUp && members.contains($0.name) }.map(\.name)
            var rc: Int32 = 0
            if !down.isEmpty { rc = setState(down, up: false) }
            if !up.isEmpty, rc == 0 { rc = setState(up, up: true) }
            return rc
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
                var d: [String: Any] = ["name": t.name, "up": t.isUp, "path": t.path,
                                        "autoConnect": AutoConnect.tunnels.contains(t.name)]
                if let s {
                    d["interface"] = s.iface ?? NSNull()
                    d["address"] = s.address ?? NSNull()
                    d["rxBytes"] = s.rx
                    d["txBytes"] = s.tx
                    d["lastHandshake"] = s.handshake.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull()
                }
                return d
            }
            let data = try! JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return 0
        }
        for t in tunnels {
            var line = "\(t.isUp ? "up  " : "down")  \(t.name.padding(toLength: 16, withPad: " ", startingAt: 0))"
            if let s = stats[t.name] {
                line += " \(s.iface ?? "-")  \(s.address ?? "-")  ↓\(formatBytes(s.rx)) ↑\(formatBytes(s.tx))"
                if let h = s.handshake { line += "  handshake \(formatAgo(h))" }
            }
            print(line)
        }
        return 0
    }

    static func setState(_ names: [String], up: Bool) -> Int32 {
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
        let tools = Helper.isInstalled ? Helper.dir : (findBinary("wg-quick") as NSString?)?.deletingLastPathComponent
        guard let tools, let bash = Helper.isInstalled ? "\(Helper.dir)/bash" : findBinary("bash") else {
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
