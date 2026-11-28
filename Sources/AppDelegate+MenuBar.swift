import AppKit
import Network
import QuartzCore
import ServiceManagement

/// Menu bar menu, Dock menu and app menu.
extension AppDelegate {
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
            for name in sharedConfigSuspects.sorted() {
                let mi = item("Resume Auto-restart for \(name)", #selector(resumeAutoRestart(_:)))
                mi.representedObject = name
                menu.addItem(mi)
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
        menu.addItem(item("Network Inspector…", #selector(showInspector), key: "i"))
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
        if !tunnels.isEmpty {
            menu.addItem(submenu("Connectivity Check", tunnels.map { t in
                let target = ConnectivityCheck.targets[t.name]
                let mi = item(target.map { "\(t.name): \($0)…" } ?? "\(t.name)…", #selector(editConnectivityCheck(_:)))
                mi.representedObject = t.name
                mi.state = target == nil ? .off : .on
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

    func tunnelTitle(_ t: Tunnel) -> NSAttributedString {
        let s = NSMutableAttributedString(string: t.name, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        if t.state == .unknown {
            s.append(NSAttributedString(string: "\nstatus unknown: config not readable", attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]))
            return s
        }
        guard t.isUp, let st = stats[t.name] else { return s }
        var parts: [String] = []
        if sharedConfigSuspects.contains(t.name) { parts.append("⚠︎ may be in use on another device, auto-restart paused") }
        else if st.stuck { parts.append("⚠︎ stuck: no replies") }
        if !st.stalePeers.isEmpty { parts.append("⚠︎ peer \(st.stalePeers.joined(separator: ", ")) not responding") }
        if let c = st.check { parts.append(c.ok ? "✓ check ok" : "⚠︎ check failed") }
        if let h = st.handshake { parts.append("handshake \(formatAgo(h))") }
        if st.iface != nil { parts.append("↓\(formatBytes(st.rx)) ↑\(formatBytes(st.tx))") }
        if let a = st.address { parts.append(a) }
        guard !parts.isEmpty else { return s }
        s.append(NSAttributedString(string: "\n" + parts.joined(separator: " · "), attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: st.stuck || !st.stalePeers.isEmpty || sharedConfigSuspects.contains(t.name) || st.check?.ok == false
                ? NSColor.systemOrange : NSColor.secondaryLabelColor,
        ]))
        return s
    }

    @objc func copyIP(_ sender: NSMenuItem) {
        guard let a = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(a, forType: .string)
    }

    func settingsMenu() -> NSMenuItem {
        func toggle(_ title: String, _ on: Bool, _ sel: Selector) -> NSMenuItem {
            let mi = item(title, sel); mi.state = on ? .on : .off; return mi
        }
        return submenu("Settings", [
            Helper.needsUpdate ? item("Update Passwordless Helper…", #selector(updateHelper))
                : toggle("Passwordless Mode", Helper.isInstalled, #selector(togglePasswordless)),
            toggle("Use Root-Owned wg-quick", Helper.toolsInstalled, #selector(toggleTrustedTools)),
            toggle("Restart Stuck Tunnels Automatically", AutoConnect.restartStuck, #selector(toggleAutoRestart)),
            .separator(),
            toggle("Global Shortcut \(HotKey.label) (Toggle All)", HotKey.enabled, #selector(toggleHotKey)),
            toggle("Notifications", Notify.enabled, #selector(toggleNotifications)),
            toggle("Show in Dock", Dock.visible, #selector(toggleDock)),
            toggle("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)),
            toggle("Check for Updates Automatically", Updates.auto, #selector(toggleUpdates)),
        ])
    }

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
}
