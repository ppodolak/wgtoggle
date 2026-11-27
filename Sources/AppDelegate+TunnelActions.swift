import AppKit
import Network
import QuartzCore
import ServiceManagement

/// Connecting/disconnecting, hook approval, busy animation, health, auto-connect and profiles.
extension AppDelegate {
    @objc func toggle(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let t = listTunnels().first(where: { $0.path == path }) else { return }
        setState([t], up: !t.isUp)
    }

    @objc func allUp() { setState(listTunnels().filter { !$0.isUp }, up: true) }

    @objc func allDown() { setState(listTunnels().filter { $0.isUp }, up: false) }

    func setState(_ tunnels: [Tunnel], up: Bool) {
        // Every config is re-read and hook-checked right before it runs as root.
        let allowed = tunnels.filter { ensureHooksApproved($0) }
        guard !allowed.isEmpty else { return }
        let verb = up ? "up" : "down"
        if up { allowed.forEach { userDisconnected.remove($0.name) } } else { allowed.forEach { userDisconnected.insert($0.name) } }
        Log.info("wg-quick \(verb): \(allowed.map(\.name).joined(separator: ", "))")
        // "up" stops at the first failure; "down" keeps going so one bad tunnel doesn't strand others.
        // Passwordless for root-owned /etc/wireguard configs when the helper is installed.
        let viaHelper = Helper.isInstalled ? allowed.filter { $0.path.hasPrefix(Helper.configDir + "/") } : []
        let viaAdmin = allowed.filter { t in !viaHelper.contains { $0.path == t.path } }
        let cmd = viaAdmin.map { wgQuick(verb, $0.path) }.joined(separator: up ? " && " : "; ")
        let names = allowed.map(\.name).joined(separator: ", ")
        runTask(what: "wg-quick \(verb)", status: "\(up ? "Connecting" : "Disconnecting") \(names)…", needsPrompt: !viaAdmin.isEmpty) {
            var out = ""
            for t in viaHelper {
                do { out += try Helper.run([verb, t.name]) } catch {
                    if up { throw error }
                    out += "\(t.name): \(error.localizedDescription)\n"
                }
            }
            if !cmd.isEmpty { out += try runAsAdmin(cmd) }
            return out
        }
    }

    /// Returns false if the config can't be read or the user rejects its hooks.
    func ensureHooksApproved(_ t: Tunnel) -> Bool {
        guard let data = FileManager.default.contents(atPath: t.path) else {
            // Root-owned (e.g. /etc/wireguard) — can't inspect, but also not user-writable, so trust it.
            if t.path.hasPrefix("/etc/") { return true }
            Log.error("cannot read \(t.path)")
            Notify.error("Can't read \(t.name)", t.path)
            return false
        }
        let hooks = hookLines(String(decoding: data, as: UTF8.self))
        if hooks.isEmpty || HookApproval.isApproved(data) { return true }
        Log.warn("\(t.name) has unapproved hooks (\(hooks.count) lines) — asking user")
        guard approveHooks(name: t.name, hooks: hooks) else {
            Log.warn("user rejected hooks for \(t.name)")
            return false
        }
        HookApproval.approve(data)
        Log.info("user approved hooks for \(t.name) sha256=\(sha256(data).prefix(12))")
        return true
    }

    func approveHooks(name: String, hooks: [String]) -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "\(name) runs commands as root"
        a.informativeText = "This config is new or changed since you last approved it. wg-quick will run these lines with administrator privileges:\n\n"
            + hooks.prefix(12).joined(separator: "\n") + (hooks.count > 12 ? "\n…" : "")
            + "\n\nOnly allow this if you trust where the config came from."
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Allow")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertSecondButtonReturn
    }

    func run(_ command: String, what: String, status: String? = nil) {
        runTask(what: what, status: status) { try runAsAdmin(command) }
    }

    /// `needsPrompt`: the work may show the admin password dialog. NSAppleScript can only present it
    /// from the main thread (from a background thread it fails with "Authorization failed"), so that
    /// work runs on main; the icon keeps pulsing via Core Animation. Helper (sudo -n) work runs in the background.
    func runTask(what: String, status: String? = nil, needsPrompt: Bool = true, _ work: @escaping () throws -> String) {
        guard busy == nil else { Log.warn("\(what) ignored: busy with \(busy!)"); return }
        guard let lock = OpLock.acquire(wait: 0) else {
            Log.warn("\(what) skipped: a wgtoggle command is running")
            Notify.error("WGToggle is busy", "A wgtoggle command in the terminal is changing tunnels. Try again when it's done.")
            return
        }
        busy = status ?? "Working…"
        startBlink()
        CATransaction.flush()   // commit the pulse animation before main shows the password dialog
        // Always off the main thread: runAsAdmin shows its dialog on main and waits for the root job here,
        // so the menu and icon stay responsive while an install or wg-quick runs.
        adminQueue.async {
            var failure: String?
            var cancelled = false
            do {
                let out = try work()
                Log.info("\(what) ok", detail: out.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch let e as NSError where e.code == -128 {
                cancelled = true
            } catch {
                failure = error.localizedDescription
            }
            Helper.invalidateCache()
            DispatchQueue.main.async {
                OpLock.release(lock)
                self.busy = nil
                self.stopBlink()
                if cancelled { Log.info("\(what): admin prompt cancelled") }
                if let failure {
                    Log.error("\(what) failed", detail: failure)
                    Notify.error("\(what) failed", failure)
                }
                self.refreshIcon()
            }
        }
    }

    /// Pulses the menu bar icon (and steps the shield fill) while a tunnel is connecting/disconnecting.
    func startBlink() {
        statusItem.button?.toolTip = busy
        var phase = 0
        let frames = ["shield", "shield.lefthalf.filled", "shield.fill", "shield.lefthalf.filled"]
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            phase += 1
            let img = NSImage(systemSymbolName: frames[phase % frames.count], accessibilityDescription: "Connecting")?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
            img?.isTemplate = true
            button.image = img
        }
        RunLoop.main.add(blinkTimer!, forMode: .common)   // keep animating while the menu is open
        if let button = statusItem.button {
            button.wantsLayer = true
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.3
            pulse.duration = 0.55
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            button.layer?.add(pulse, forKey: "pulse")
        }
    }

    func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        statusItem.button?.layer?.removeAnimation(forKey: "pulse")
        statusItem.button?.alphaValue = 1
    }

    func sampleStats() {
        if demoMode { stats = Demo.stats.filter { Demo.up.contains($0.key) }; refreshIcon(); return }
        let tunnels = listTunnels()
        statsQueue.async { [weak self] in
            guard let self else { return }
            let r = self.health.sample(tunnels: tunnels)
            DispatchQueue.main.async {
                self.stats = r.stats
                for name in r.newlyStuck { self.handleStuck(name) }
                for (name, peer) in r.newlyStalePeers {
                    Log.warn("\(name): peer \(peer) gets traffic but no handshake")
                    Notify.error("\(name): a peer isn't responding", "Peer \(peer) gets traffic but hasn't completed a handshake. Other peers of this tunnel still work.")
                }
                self.refreshIcon()
            }
        }
    }

    func handleStuck(_ name: String) {
        Log.warn("\(name) looks stuck: traffic goes out but nothing comes back")
        Notify.error("\(name) looks stuck", AutoConnect.restartStuck
            ? "Traffic goes out but nothing comes back. Restarting it…"
            : "Traffic goes out but nothing comes back. Is the same config active on another device?")
        guard AutoConnect.restartStuck, let t = listTunnels().first(where: { $0.name == name }), ensureHooksApproved(t) else { return }
        guard let delay = restartDelay(previous: restarts[name] ?? []) else {
            Log.warn("\(name): restarted 3 times in 15 minutes, giving up for now")
            Notify.error("\(name) keeps failing", "Restarted 3 times in 15 minutes. Not trying again for a while; check the server or the log.")
            return
        }
        restarts[name, default: []].append(Date())
        restarts[name] = restarts[name]?.filter { Date().timeIntervalSince($0) < 15 * 60 }   // keep it bounded
        Log.info("\(name): restarting in \(Int(delay))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // The user may have disconnected it (or turned auto-restart off) while we waited.
            guard let self, AutoConnect.restartStuck, !self.userDisconnected.contains(name),
                  let current = listTunnels().first(where: { $0.name == name }), current.isUp else {
                Log.info("\(name): scheduled restart cancelled"); return
            }
            self.restart(current)
        }
    }

    func restart(_ t: Tunnel) {
        let viaHelper = Helper.isInstalled && t.path.hasPrefix(Helper.configDir + "/")
        runTask(what: "restart \(t.name)", status: "Restarting \(t.name)…", needsPrompt: !viaHelper) {
            if viaHelper {
                _ = try? Helper.run(["down", t.name])
                return try Helper.run(["up", t.name])
            }
            return try runAsAdmin(wgQuick("down", t.path) + "; " + wgQuick("up", t.path))
        }
    }

    /// Auto-connect at launch; after wake and network changes too when passwordless (no surprise prompts).
    func setupAutoConnect() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.autoConnect(reason: "launch") }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.autoConnect(reason: "wake") }
        }
        let monitor = NWPathMonitor()
        var wasSatisfied = true
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            if ok && !wasSatisfied { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.autoConnect(reason: "network change") } }
            wasSatisfied = ok
        }
        monitor.start(queue: DispatchQueue(label: "wgtoggle.path"))
        pathMonitor = monitor
    }

    func autoConnect(reason: String) {
        if reason != "launch" && !Helper.isInstalled { return }
        let want = listTunnels().filter { AutoConnect.tunnels.contains($0.name) && !$0.isUp }
        guard !want.isEmpty, busy == nil else { return }
        Log.info("auto-connect (\(reason)): \(want.map(\.name).joined(separator: ", "))")
        setState(want, up: true)
    }

    @objc func toggleAutoConnect(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? String else { return }
        if AutoConnect.tunnels.contains(n) { AutoConnect.tunnels.remove(n) } else { AutoConnect.tunnels.insert(n) }
        Log.info("auto-connect \(n): \(AutoConnect.tunnels.contains(n))")
    }

    func toggleAllShortcut() {
        let t = listTunnels()
        if t.contains(where: { $0.isUp }) { allDown() } else { allUp() }
    }

    @objc func activateProfile(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let members = Profiles.all[name] else { return }
        let tunnels = listTunnels()
        let down = tunnels.filter { $0.isUp && !members.contains($0.name) }
        let up = tunnels.filter { !$0.isUp && members.contains($0.name) }
        Log.info("profile \(name): up \(up.map(\.name)), down \(down.map(\.name))")
        if !down.isEmpty { setState(down, up: false) }
        if !up.isEmpty {
            // setState is one-at-a-time; queue the "up" half after the "down" half finishes.
            func go() { if busy == nil { setState(up, up: true) } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { go() } } }
            go()
        }
    }

    @objc func saveProfile() {
        let upNames = listTunnels().filter { $0.isUp }.map(\.name)
        guard !upNames.isEmpty else { alert("No tunnels are up", "Connect the tunnels you want in the profile first."); return }
        let a = NSAlert()
        a.messageText = "Save profile"
        a.informativeText = "Tunnels: \(upNames.joined(separator: ", "))"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        f.placeholderString = "e.g. Work"
        a.accessoryView = f
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Profiles.all[name] = upNames
        Log.info("profile saved: \(name) = \(upNames)")
    }

    @objc func deleteProfile(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? String else { return }
        Profiles.all[n] = nil
        Log.info("profile deleted: \(n)")
    }
}
