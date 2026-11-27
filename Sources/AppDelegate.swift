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
    /// Privileged commands run one at a time on this queue so the UI (and the icon animation) stays live.
    let adminQueue = DispatchQueue(label: "wgtoggle.admin")
    var busy: String?            // e.g. "Connecting wg-dev…" while a command runs
    var blinkTimer: Timer?

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
        // Older helper after an app update: features silently missing otherwise, so say it once per launch.
        if Helper.needsUpdate {
            Log.warn("passwordless helper v\(Helper.installedVersion) is older than v\(Helper.currentVersion)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Notify.helperUpdateNeeded(installed: Helper.installedVersion) }
        }
        // After a crash or reboot, resolvers of tunnels that aren't running anymore can be left behind.
        if Helper.isInstalled && Helper.installedVersion >= 4 {
            DispatchQueue.global().async {
                if let out = try? Helper.run(["dns-repair"]), !out.contains("nothing to repair"), !out.isEmpty {
                    Log.info("dns repair at launch", detail: out.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
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

    func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        items.forEach { sub.addItem($0) }
        mi.submenu = sub
        return mi
    }

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
