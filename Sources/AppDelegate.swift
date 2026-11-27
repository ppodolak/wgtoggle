import AppKit
import QuartzCore
import Network
import ServiceManagement

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var installing = false
    var installError: String?
    var lastState: [String: Bool] = [:]
    let health = HealthMonitor()
    let statsQueue = DispatchQueue(label: "wgtoggle.stats")
    var stats: [String: TunnelStats] = [:]
    var availableUpdate: Updates.Release?
    var pathMonitor: NWPathMonitor?
    var userDisconnected = Set<String>()
    var restarts: [String: [Date]] = [:]

    func applicationDidFinishLaunching(_ note: Notification) {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        Log.info("WGToggle \(v) started; tunnels: \(listTunnels().map(\.name).joined(separator: ", "))")
        Notify.setup()
        installMainMenu()
        Dock.apply()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshIcon() }
        sampleStats()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.sampleStats() }
        HotKey.action = { [weak self] in self?.toggleAllShortcut() }
        HotKey.apply()
        setupAutoConnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.checkForUpdates(manual: false) }
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.checkForUpdates(manual: false) }
        Log.info("passwordless mode: \(Helper.isInstalled ? "on" : "off")")
        if CommandLine.arguments.contains("--show-logs") { MainActor.assumeIsolated { LogExplorer.show() } }
        if CommandLine.arguments.contains("--show-about") { showAbout() }
        // README screenshots: open the menu bar menu programmatically.
        if CommandLine.arguments.contains("--show-menu") {
            // Plain backdrop so the translucent menu doesn't pick up whatever is on screen.
            if demoMode, let screen = NSScreen.main {
                let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                w.backgroundColor = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
                w.isReleasedWhenClosed = false
                w.orderFrontRegardless()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.statusItem.button?.performClick(nil) }
        }
        if demoMode {
            try? FileManager.default.removeItem(at: Log.file)
            for (lvl, msg) in [("i", "WGToggle \(Updates.current) started; tunnels: dev, homelab, prod"), ("i", "wg-quick up: dev"),
                               ("i", "dev is now UP"), ("i", "wg-quick up: prod"), ("i", "prod is now UP"),
                               ("w", "homelab has unapproved hooks (2 lines), asking user"), ("i", "user approved hooks for homelab"),
                               ("e", "wg-quick up failed"), ("w", "prod looks stuck: traffic goes out but nothing comes back"),
                               ("i", "restart prod ok")] {
                lvl == "i" ? Log.info(msg) : lvl == "w" ? Log.warn(msg) : Log.error(msg, detail: "Endpoint not reachable")
            }
        }
        if findBinary("wg-quick") == nil {
            Log.warn("wg-quick not found in \(binDirs)")
            installTools()
        }
    }

    func applicationWillTerminate(_ note: Notification) { Log.info("WGToggle quit") }

    // Rebuild the menu each time it opens so status is always current.
    func menuNeedsUpdate(_ menu: NSMenu) { buildMenu() }

    func refreshIcon() {
        if busy != nil { return }
        let tunnels = listTunnels()
        let up = tunnels.filter { $0.isUp }

        // Log state changes, including ones made outside the app (e.g. wg-quick in a terminal).
        let state = Dictionary(uniqueKeysWithValues: tunnels.map { ($0.name, $0.isUp) })
        if !lastState.isEmpty {
            for (name, isUp) in state where lastState[name] != isUp {
                Log.info("\(name) is now \(isUp ? "UP" : "DOWN")")
                isUp ? Notify.connected(name) : Notify.disconnected(name)
                // Dropped on its own (wireguard-go died, sleep, network change): bring it back.
                if !isUp && !userDisconnected.contains(name) && AutoConnect.tunnels.contains(name) && Helper.isInstalled {
                    Log.warn("\(name) dropped unexpectedly, reconnecting")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.autoConnect(reason: "drop") }
                }
            }
        }
        lastState = state

        let anyStuck = stats.values.contains { $0.stuck }
        let symbol = anyStuck ? "exclamationmark.shield.fill"
            : up.isEmpty ? "shield" : (up.count == tunnels.count ? "shield.fill" : "shield.lefthalf.filled")
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "WireGuard")?.withSymbolConfiguration(cfg)
        img?.isTemplate = true   // monochrome, adapts to light/dark menu bar
        statusItem.button?.image = img
        statusItem.button?.toolTip = anyStuck ? "WireGuard: a tunnel looks stuck"
            : up.isEmpty ? "WireGuard: all down" : "WireGuard up: " + up.map(\.name).joined(separator: ", ")
    }

    func buildMenu(_ target: NSMenu? = nil) {
        let menu = target ?? self.menu
        menu.removeAllItems()

        if findBinary("wg-quick") == nil {
            if installing {
                menu.addItem(disabled("Installing wireguard-tools…"))
            } else if findBinary("brew") == nil {
                menu.addItem(disabled("wg-quick not found — Homebrew required"))
                menu.addItem(item("Get Homebrew…", #selector(openBrew)))
            } else {
                if let installError { menu.addItem(disabled("Install failed: \(installError.prefix(60))")) }
                menu.addItem(item("Install wireguard-tools", #selector(installToolsAction)))
            }
            menu.addItem(.separator())
        }

        if let busy {
            menu.addItem(disabled(busy))
            menu.addItem(.separator())
        }

        let tunnels = listTunnels()
        if tunnels.isEmpty {
            menu.addItem(disabled("No configs in \(preferredConfigDir)"))
        } else {
            menu.addItem(disabled("Tunnels"))
            for t in tunnels {
                let mi = item(t.name, #selector(toggle(_:)))
                mi.state = t.isUp ? .on : .off
                mi.representedObject = t.path
                mi.toolTip = t.path
                mi.isEnabled = findBinary("wg-quick") != nil && busy == nil
                mi.attributedTitle = tunnelTitle(t)
                menu.addItem(mi)
                // Hold ⌥ to copy the tunnel's IP instead.
                if let addr = stats[t.name]?.address {
                    let alt = item("Copy \(t.name) IP  \(addr)", #selector(copyIP(_:)))
                    alt.representedObject = addr
                    alt.isAlternate = true
                    alt.keyEquivalentModifierMask = .option
                    menu.addItem(alt)
                }
            }
            menu.addItem(.separator())
            menu.addItem(item("Connect All", #selector(allUp)))
            menu.addItem(item("Disconnect All", #selector(allDown)))
            menu.addItem(profilesMenu(tunnels))
        }

        menu.addItem(.separator())
        menu.addItem(item("Import Config Files…", #selector(importConfig)))
        menu.addItem(item("Add Tunnel (Paste Config)…", #selector(pasteConfig)))
        menu.addItem(item("Import QR Code…", #selector(importQR)))
        if !tunnels.isEmpty {
            menu.addItem(submenu("Edit Tunnel", tunnels.map { t in
                let mi = item(t.name, #selector(editTunnel(_:))); mi.representedObject = t.path; return mi
            }))
            let rm = NSMenuItem(title: "Remove Tunnel", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for t in tunnels {
                let mi = item(t.name, #selector(removeTunnel(_:)))
                mi.representedObject = t.path
                sub.addItem(mi)
            }
            rm.submenu = sub
            menu.addItem(rm)
        }
        menu.addItem(item("Open Config Directory", #selector(openFolder)))
        menu.addItem(item("Log Explorer…", #selector(showLog), key: "l"))
        menu.addItem(.separator())
        if !tunnels.isEmpty {
            menu.addItem(submenu("Auto-connect", tunnels.map { t in
                let mi = item(t.name, #selector(toggleAutoConnect(_:)))
                mi.representedObject = t.name
                mi.state = AutoConnect.tunnels.contains(t.name) ? .on : .off
                return mi
            }))
        }
        menu.addItem(settingsMenu())
        if let u = availableUpdate {
            menu.addItem(item("Update Available: v\(u.version)…", #selector(openUpdate)))
        } else {
            menu.addItem(item("Check for Updates…", #selector(checkForUpdatesManual)))
        }
        menu.addItem(.separator())
        menu.addItem(item("About WGToggle", #selector(showAbout)))
        menu.addItem(item("Buy Me a Coffee…", #selector(openDonate)))
        menu.addItem(item("Quit", #selector(quit), key: "q"))
    }

    func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        return mi
    }

    func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    // MARK: Up / down

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
        let cmd = viaAdmin.map { "wg-quick \(verb) \(shellQuote($0.path))" }.joined(separator: up ? " && " : "; ")
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

    /// Privileged commands run one at a time on this queue so the UI (and the icon animation) stays live.
    let adminQueue = DispatchQueue(label: "wgtoggle.admin")
    var busy: String?            // e.g. "Connecting wg-dev…" while a command runs
    var blinkTimer: Timer?

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
        CATransaction.flush()   // commit the pulse animation before main may block on the dialog
        let queue = needsPrompt ? DispatchQueue.main : adminQueue
        queue.async {
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

    // MARK: Import / add / remove

    @objc func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "conf")!]
        panel.allowsMultipleSelection = true
        panel.message = "Select one or more WireGuard .conf files"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// Files dropped on the app icon / opened with the app.
    func application(_ sender: NSApplication, open urls: [URL]) {
        importFiles(urls.filter { $0.pathExtension == "conf" })
    }

    func importFiles(_ urls: [URL]) {
        for url in urls {
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 64_000,
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                Log.error("import: cannot read \(url.path) (missing, too big or not UTF-8)")
                alert("Can't import file", "\(url.path)\n\nMissing, larger than 64 KB, or not a text file.")
                continue
            }
            Log.info("import: \(url.path)")
            addTunnel(suggestedName: url.deletingPathExtension().lastPathComponent, contents: text)
        }
    }

    /// Paste a config (e.g. copied from WireGuard Portal).
    @objc func pasteConfig() {
        let a = NSAlert()
        a.messageText = "Add Tunnel"
        a.informativeText = "Name (max 15 chars) and the config contents:"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 270))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 244, width: 420, height: 24))
        nameField.placeholderString = "e.g. wg-staging"
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 236)
        scroll.borderType = .bezelBorder
        let tv = scroll.documentView as! NSTextView
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        if let clip = NSPasteboard.general.string(forType: .string), clip.contains("[Interface]") { tv.string = clip }
        box.addSubview(nameField)
        box.addSubview(scroll)
        a.accessoryView = box
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = nameField
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Log.info("paste: adding tunnel '\(nameField.stringValue)'")
        addTunnel(suggestedName: nameField.stringValue, contents: tv.string)
    }

    func addTunnel(suggestedName: String, contents original: String, editing: Bool = false) {
        var contents = original
        guard contents.contains("[Interface]"), contents.contains("[Peer]"),
              !confValues(contents, key: "privatekey").isEmpty else {
            Log.warn("add: '\(suggestedName)' rejected — not a WireGuard client config")
            alert("Not a WireGuard config", "\"\(suggestedName)\" needs [Interface] with a PrivateKey and a [Peer] section.")
            return
        }
        var name = suggestedName.trimmingCharacters(in: .whitespaces)
        if !isValidName(name) {
            guard let n = askName(for: name) else { return }
            name = n
        }
        let existing = listTunnels().filter { $0.name != name }
        if !editing, let t = listTunnels().first(where: { $0.name == name }), !confirm("Replace existing \(name)?\n\(t.path)") { return }

        // Global DNS breaks other tunnels and normal internet DNS: offer split DNS instead.
        let hadHooks = !hookLines(contents).isEmpty
        var generatedHooks = false
        if let plan = SplitDNS.plan(contents) {
            switch askSplitDNS(name: name, plan: plan) {
            case .convert:
                contents = SplitDNS.convert(contents, plan: plan)
                generatedHooks = !plan.domains.isEmpty && !plan.servers.isEmpty
                Log.info("add: \(name) converted to split DNS for \(plan.domains.joined(separator: ", "))")
            case .keep: break
            case .cancel: return
            }
        }

        let clashes = conflicts(name: name, conf: contents,
                                others: existing.compactMap { t in configText(t).map { (t.name, $0) } })
        if !clashes.isEmpty {
            Log.warn("add: \(name) warnings: \(clashes.joined(separator: " | "))")
            if !confirm("\(name) may disturb other tunnels or your internet:\n\n"
                        + clashes.prefix(8).joined(separator: "\n") + "\n\nAdd anyway?", button: "Add Anyway") { return }
        }

        // Hooks run as root: approve at import time so connecting later doesn't surprise the user.
        let data = Data(contents.utf8)
        let hooks = hookLines(contents)
        if !hooks.isEmpty {
            // Hooks we just generated from the DNS line were already shown in the split-DNS dialog.
            if !(generatedHooks && !hadHooks) {
                guard approveHooks(name: name, hooks: hooks) else { Log.warn("add: \(name) hooks rejected"); return }
            }
            HookApproval.approve(data)
        }

        let dir = preferredConfigDir
        let dest = "\(dir)/\(name).conf"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if fm.isWritableFile(atPath: dir) {
            // Write to a 0600 temp file in the same dir, then atomically rename over the target:
            // never follows a symlink at `dest` and the key is never world-readable.
            let tmp = "\(dir)/.\(name).\(UUID().uuidString).tmp"
            guard fm.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]),
                  rename(tmp, dest) == 0 else {
                try? fm.removeItem(atPath: tmp)
                Log.error("add: failed writing \(dest)")
                alert("Couldn't save config", dest)
                return
            }
            Log.info("add: saved \(dest)")
        } else {
            // Root-owned dir: stage in the user's private temp dir, then let root copy the *contents*
            // (`install` reads through, writes a fresh root-owned 0600 file; no chmod on a swappable path).
            let tmp = NSTemporaryDirectory() + UUID().uuidString
            fm.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600])
            run("/usr/bin/install -m 600 \(shellQuote(tmp)) \(shellQuote(dest)); rc=$?; rm -f \(shellQuote(tmp)); exit $rc",
                what: "save \(name)")
        }
    }

    @objc func removeTunnel(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let t = listTunnels().first(where: { $0.path == path }) else { return }
        guard confirm("Delete tunnel \(t.name)?\n\(path)", button: "Delete") else { return }
        Log.info("remove: \(t.name) (\(path))")
        var cmd = ""
        if t.isUp { cmd = "wg-quick down \(shellQuote(path)); " }
        if t.isUp || (try? FileManager.default.removeItem(atPath: path)) == nil {
            run(cmd + "rm -f \(shellQuote(path))", what: "remove \(t.name)")
        }
    }

    func askName(for original: String) -> String? {
        let a = NSAlert()
        a.messageText = "Choose a tunnel name"
        a.informativeText = "\"\(original)\" can't be used as an interface name (max 15 characters: letters, digits, _ = + . -)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = String(original.filter { isValidName(String($0)) }.suffix(15))
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Skip")
        NSApp.activate(ignoringOtherApps: true)
        while a.runModal() == .alertFirstButtonReturn {
            if isValidName(field.stringValue) { return field.stringValue }
            a.informativeText = "Invalid name. Max 15 characters: letters, digits, _ = + . -"
        }
        return nil
    }

    // MARK: Misc

    @objc func openFolder() {
        let dir = listTunnels().first.map { ($0.path as NSString).deletingLastPathComponent } ?? preferredConfigDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    @objc func showLog() {
        Log.queue.sync {}  // flush
        MainActor.assumeIsolated { LogExplorer.show() }  // menu actions run on main
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            Log.info("launch at login: \(SMAppService.mainApp.status == .enabled)")
        } catch {
            Log.error("launch at login failed: \(error.localizedDescription)")
            alert("Launch at Login", "\(error.localizedDescription)\n\nMove the app to /Applications and try again.")
        }
    }

    @objc func toggleDock() {
        Dock.visible.toggle()
        Dock.apply()
        Log.info("show in Dock: \(Dock.visible)")
    }

    // Dock icon click → Log Explorer; right-click → same menu as the menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { LogExplorer.show() } }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        buildMenu(m)
        // The Dock adds its own Quit / Options; drop ours to avoid duplicates.
        if let q = m.items.last, q.action == #selector(quit) {
            m.removeItem(q)
            if m.items.last?.isSeparatorItem == true { m.removeItem(at: m.items.count - 1) }
        }
        return m
    }

    /// App + Edit + Window menus: shown in the menu bar when the app is in the Dock, and they make
    /// ⌘C/⌘V/⌘A/⌘W work in the Log Explorer either way.
    func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(item("About WGToggle", #selector(showAbout)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Log Explorer…", #selector(showLog), key: "l"))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide WGToggle", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit WGToggle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    @objc func toggleNotifications() {
        Notify.enabled.toggle()
        Log.info("notifications \(Notify.enabled ? "on" : "off")")
    }

    @objc func installToolsAction() { installTools() }

    func installTools() {
        guard let brew = findBinary("brew"), !installing else { return }
        installing = true
        installError = nil
        Log.info("installing wireguard-tools via \(brew)")
        DispatchQueue.global().async {
            let p = Process()
            let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: brew)
            p.arguments = ["install", "wireguard-tools"]
            p.environment = ProcessInfo.processInfo.environment.merging(
                ["HOMEBREW_NO_AUTO_UPDATE": "1", "NONINTERACTIVE": "1"]) { $1 }
            p.standardOutput = pipe
            p.standardError = pipe
            try? p.run()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            DispatchQueue.main.async {
                self.installing = false
                if p.terminationStatus != 0 || findBinary("wg-quick") == nil {
                    self.installError = out.split(separator: "\n").last.map(String.init) ?? "unknown error"
                    Log.error("brew install failed (exit \(p.terminationStatus))", detail: String(out.suffix(2000)))
                    Notify.error("Installing wireguard-tools failed", self.installError ?? "")
                    self.alert("Installing wireguard-tools failed", String(out.suffix(1500)))
                } else {
                    Log.info("wireguard-tools installed")
                    Notify.post(title: "wireguard-tools installed", body: "wg-quick is ready.")
                }
            }
        }
    }

    // MARK: Stats, health, auto-connect, updates, profiles, QR, edit

    func tunnelTitle(_ t: Tunnel) -> NSAttributedString {
        let s = NSMutableAttributedString(string: t.name, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        guard t.isUp, let st = stats[t.name] else { return s }
        var parts: [String] = []
        if st.stuck { parts.append("⚠︎ stuck: no replies") }
        if let h = st.handshake { parts.append("handshake \(formatAgo(h))") }
        if st.iface != nil { parts.append("↓\(formatBytes(st.rx)) ↑\(formatBytes(st.tx))") }
        if let a = st.address { parts.append(a) }
        guard !parts.isEmpty else { return s }
        s.append(NSAttributedString(string: "\n" + parts.joined(separator: " · "), attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: st.stuck ? NSColor.systemOrange : NSColor.secondaryLabelColor,
        ]))
        return s
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
        Log.info("\(name): restarting in \(Int(delay))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.restart(t) }
    }

    func restart(_ t: Tunnel) {
        let viaHelper = Helper.isInstalled && t.path.hasPrefix(Helper.configDir + "/")
        runTask(what: "restart \(t.name)", status: "Restarting \(t.name)…", needsPrompt: !viaHelper) {
            if viaHelper {
                _ = try? Helper.run(["down", t.name])
                return try Helper.run(["up", t.name])
            }
            return try runAsAdmin("wg-quick down \(shellQuote(t.path)); wg-quick up \(shellQuote(t.path))")
        }
    }

    @objc func copyIP(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(a, forType: .string)
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

    func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        items.forEach { sub.addItem($0) }
        mi.submenu = sub
        return mi
    }

    func settingsMenu() -> NSMenuItem {
        func toggle(_ title: String, _ on: Bool, _ sel: Selector) -> NSMenuItem {
            let mi = item(title, sel); mi.state = on ? .on : .off; return mi
        }
        return submenu("Settings", [
            Helper.needsUpdate ? item("Update Passwordless Helper…", #selector(updateHelper))
                : toggle("Passwordless Mode", Helper.isInstalled, #selector(togglePasswordless)),
            toggle("Restart Stuck Tunnels Automatically", AutoConnect.restartStuck, #selector(toggleAutoRestart)),
            .separator(),
            toggle("Global Shortcut \(HotKey.label) (Toggle All)", HotKey.enabled, #selector(toggleHotKey)),
            toggle("Notifications", Notify.enabled, #selector(toggleNotifications)),
            toggle("Show in Dock", Dock.visible, #selector(toggleDock)),
            toggle("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)),
            toggle("Check for Updates Automatically", Updates.auto, #selector(toggleUpdates)),
        ])
    }

    @objc func toggleAutoRestart() { AutoConnect.restartStuck.toggle(); Log.info("auto-restart stuck: \(AutoConnect.restartStuck)") }
    @objc func toggleHotKey() { HotKey.enabled.toggle(); HotKey.apply(); Log.info("global shortcut: \(HotKey.enabled)") }
    @objc func toggleUpdates() { Updates.auto.toggle(); Log.info("auto update check: \(Updates.auto)") }

    @objc func togglePasswordless() {
        if Helper.isInstalled {
            guard confirm("Turn off passwordless mode?\n\nConfigs stay in \(Helper.configDir). Connecting will ask for your password again.",
                          button: "Turn Off") else { return }
            runTask(what: "uninstall helper", status: "Removing helper…") { try Helper.uninstall(); return "removed" }
            return
        }
        let movable = listTunnels().filter { !$0.path.hasPrefix(Helper.configDir + "/") }
        // Every config moved into the root-owned dir must have approved hooks first.
        guard movable.allSatisfy({ ensureHooksApproved($0) }) else { return }
        let a = NSAlert()
        a.messageText = "Turn on passwordless mode?"
        a.informativeText = """
            Connecting and disconnecting will no longer ask for your password.

            One admin prompt now will:
            • copy wg-quick, wg, wireguard-go and bash into \(Helper.dir) (root-owned)
            • allow only that helper in \(Helper.sudoers)
            • move your configs into \(Helper.configDir) (root-owned, so nothing running as you can change them)

            Adding, editing or removing tunnels will still ask for your password.
            Re-run this after `brew upgrade wireguard-tools` to pick up new versions.
            """
        a.addButton(withTitle: "Turn On")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Log.info("installing helper; moving: \(movable.map(\.name).joined(separator: ", "))")
        runTask(what: "install helper", status: "Installing helper…") { try Helper.install(movingConfigs: movable) }
    }

    /// Reinstall the helper (newer script, fresh copies of the Homebrew tools). One admin prompt.
    @objc func updateHelper() {
        Log.info("updating helper to v\(Helper.currentVersion)")
        runTask(what: "update helper", status: "Updating helper…") { try Helper.install(movingConfigs: []) }
    }

    @objc func checkForUpdatesManual() { checkForUpdates(manual: true) }

    func checkForUpdates(manual: Bool) {
        guard manual || Updates.auto else { return }
        Updates.check { rel, err in
            DispatchQueue.main.async {
                if let rel {
                    let isNew = self.availableUpdate?.version != rel.version
                    self.availableUpdate = rel
                    Log.info("update available: v\(rel.version)")
                    if isNew || manual { Notify.post(title: "WGToggle \(rel.version) is available", body: "Open the menu to download it.") }
                    if manual { NSWorkspace.shared.open(rel.url) }
                } else if manual {
                    if let err { self.alert("Couldn't check for updates", err) }
                    else { self.alert("You're up to date", "WGToggle \(Updates.current) is the latest version.") }
                }
            }
        }
    }

    @objc func openUpdate() { if let u = availableUpdate { NSWorkspace.shared.open(u.url) } }

    func profilesMenu(_ tunnels: [Tunnel]) -> NSMenuItem {
        let profiles = Profiles.all
        let upNames = Set(tunnels.filter { $0.isUp }.map(\.name))
        var items: [NSMenuItem] = profiles.keys.sorted().map { name in
            let members = profiles[name] ?? []
            let mi = item("\(name)  (\(members.joined(separator: ", ")))", #selector(activateProfile(_:)))
            mi.representedObject = name
            mi.state = Set(members) == upNames && !upNames.isEmpty ? .on : .off
            return mi
        }
        if !items.isEmpty { items.append(.separator()) }
        items.append(item("Save Current as Profile…", #selector(saveProfile)))
        if !profiles.isEmpty {
            items.append(submenu("Delete Profile", profiles.keys.sorted().map { n in
                let mi = item(n, #selector(deleteProfile(_:))); mi.representedObject = n; return mi
            }))
        }
        return submenu("Profiles", items)
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

    @objc func importQR() {
        var image = NSImage(pasteboard: NSPasteboard.general)
        if image == nil {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.message = "Choose a screenshot or image of the WireGuard QR code"
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            image = NSImage(contentsOf: url)
        }
        guard let image, let text = QRImport.decode(image) else {
            alert("No QR code found", "Copy a screenshot of the QR code to the clipboard, or choose an image file.")
            return
        }
        Log.info("import: QR code decoded (\(text.count) chars)")
        addTunnel(suggestedName: "", contents: text)
    }

    @objc func editTunnel(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let t = listTunnels().first(where: { $0.path == path }) else { return }
        var text = try? String(contentsOfFile: path, encoding: .utf8)
        if text == nil {   // root-only config: read it with one admin prompt
            text = try? runAsAdmin("cat \(shellQuote(path))")
        }
        guard let text else { return }
        guard let (name, newText) = configDialog(title: "Edit \(t.name)", name: t.name, text: text, nameEditable: false),
              newText != text else { return }
        Log.info("edit: \(t.name)")
        addTunnel(suggestedName: name, contents: newText, editing: true)
    }

    enum SplitChoice { case convert, keep, cancel }

    func askSplitDNS(name: String, plan: SplitDNS.Plan) -> SplitChoice {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "\(name) sets DNS for all lookups"
        if !plan.domains.isEmpty && !plan.servers.isEmpty {
            a.informativeText = """
                While \(name) is up, every DNS lookup would go to \(plan.servers.joined(separator: ", ")). This breaks other tunnels and can slow down normal internet.

                Use split DNS instead? Only these domains will use the VPN's DNS:
                \(plan.domains.map { "• *.\($0)" }.joined(separator: "\n"))

                (The DNS line is replaced with PostUp/PostDown hooks that manage /etc/resolver/<domain>.)
                """
            a.addButton(withTitle: "Use Split DNS")
        } else {
            a.informativeText = "While \(name) is up, every DNS lookup goes to the VPN. The config doesn't name a domain, so split DNS can't be set up automatically.\n\nRemove the DNS line and keep using your normal DNS?"
            a.addButton(withTitle: "Remove DNS Line")
        }
        a.addButton(withTitle: "Keep As Is")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: return .convert
        case .alertSecondButtonReturn: return .keep
        default: return .cancel
        }
    }

    /// Shared editor for paste and edit.
    func configDialog(title: String, name: String, text: String, nameEditable: Bool = true) -> (String, String)? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = nameEditable ? "Name (max 15 chars) and the config contents:" : "Overlaps, DNS and hooks are checked when you save."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 274, width: 460, height: 24))
        nameField.placeholderString = "e.g. wg-staging"
        nameField.stringValue = name
        nameField.isEditable = nameEditable
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 460, height: 266)
        scroll.borderType = .bezelBorder
        let tv = scroll.documentView as! NSTextView
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.string = text
        box.addSubview(nameField)
        box.addSubview(scroll)
        a.accessoryView = box
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = nameEditable ? nameField : tv
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return (nameField.stringValue, tv.string)
    }

    /// Standard About panel with icon, version, contact and links.
    @objc func showAbout() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 4
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]
        func link(_ text: String, _ url: String) -> NSAttributedString {
            var a = base
            a[.link] = URL(string: url)!
            a[.foregroundColor] = NSColor.linkColor
            return NSAttributedString(string: text, attributes: a)
        }
        let credits = NSMutableAttributedString(string: "Run several WireGuard tunnels at once from the menu bar.\n\n", attributes: base)
        credits.append(NSAttributedString(string: "Paweł Podolak\n", attributes: base))
        credits.append(link("p.podolak@gmail.com", "mailto:p.podolak@gmail.com?subject=WGToggle%20\(version)"))
        credits.append(NSAttributedString(string: "\n", attributes: base))
        credits.append(link("github.com/ppodolak/wgtoggle", "https://github.com/ppodolak/wgtoggle"))
        credits.append(NSAttributedString(string: "\n", attributes: base))
        credits.append(link("Buy me a coffee", "https://buymeacoffee.com/ppodolak"))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "WGToggle",
            .applicationVersion: version,
            .version: "Build \(build)",
            .applicationIcon: NSApp.applicationIconImage as Any,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Paweł Podolak · MIT License",
        ])
    }

    @objc func openDonate() { NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/ppodolak")!) }
    @objc func openBrew() { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }
    @objc func quit() { NSApp.terminate(nil) }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    func confirm(_ text: String, button: String = "Replace") -> Bool {
        let a = NSAlert()
        a.messageText = text
        NSApp.activate(ignoringOtherApps: true)
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }
}
