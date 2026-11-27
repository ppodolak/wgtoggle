import AppKit
import Network
import QuartzCore
import ServiceManagement

/// Importing, adding, editing and removing tunnel configs.
extension AppDelegate {
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
        if t.isUp { cmd = wgQuick("down", path) + "; " }
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

    @objc func openFolder() {
        let dir = listTunnels().first.map { ($0.path as NSString).deletingLastPathComponent } ?? preferredConfigDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
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
}
