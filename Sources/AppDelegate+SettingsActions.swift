import AppKit
import Network
import QuartzCore
import ServiceManagement

/// Settings toggles, passwordless mode, updates, About and links.
extension AppDelegate {
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

    /// Root-owned copies of wg-quick & co. without the sudo rule: password prompts stay, but nothing
    /// running as you can swap the tools that run as root.
    @objc func toggleTrustedTools() {
        if Helper.isInstalled { alert("Part of passwordless mode", "Passwordless mode already uses the root-owned copies. Turn it off to remove them."); return }
        if Helper.toolsInstalled {
            runTask(what: "remove tool copies", status: "Removing…") { try runAsAdmin("rm -rf \(shellQuote(Helper.dir))") }
        } else {
            guard confirm("Install root-owned copies of wg-quick, wg, wireguard-go and bash into \(Helper.dir)?\n\nConnecting still asks for your password, but uses these copies instead of Homebrew's user-writable files. Re-run after brew upgrade wireguard-tools.", button: "Install") else { return }
            runTask(what: "install tool copies", status: "Installing…") { try Helper.install(movingConfigs: [], sudoers: false) }
        }
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
}
