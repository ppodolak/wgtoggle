import AppKit
import CryptoKit
import OSLog
import ServiceManagement

// MARK: - Logging
//
// Two sinks:
//   • Unified log (Console.app, `log stream --predicate 'subsystem == "local.wgtoggle"'`)
//   • ~/Library/Logs/WGToggle/wgtoggle.log (rotated at 1 MB, one backup kept)
// Config contents and keys are NEVER logged — only names, paths, commands and wg-quick output.

enum Log {
    static let os = Logger(subsystem: "local.wgtoggle", category: "app")
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WGToggle")
    static let file = dir.appendingPathComponent("wgtoggle.log")
    static let queue = DispatchQueue(label: "wgtoggle.log")
    static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func info(_ m: String) { os.info("\(m, privacy: .public)"); write("INFO ", m) }
    static func warn(_ m: String) { os.warning("\(m, privacy: .public)"); write("WARN ", m) }
    static func error(_ m: String) { os.error("\(m, privacy: .public)"); write("ERROR", m) }

    private static func write(_ level: String, _ m: String) {
        let line = "\(stamp.string(from: Date())) \(level) \(m)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > 1_000_000 {
                let old = file.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: file, to: old)
            }
            if !fm.fileExists(atPath: file.path) {
                fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            }
        }
    }
}

// MARK: - Paths

let binDirs = ["/opt/homebrew/bin", "/usr/local/bin"]
let configDirs = ["/opt/homebrew/etc/wireguard", "/usr/local/etc/wireguard", "/etc/wireguard"]
let runDir = "/var/run/wireguard"   // wg-quick (macOS) writes <name>.name here while a tunnel is up

func findBinary(_ name: String) -> String? {
    binDirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Where imported configs go: the Homebrew prefix that holds wg-quick.
var preferredConfigDir: String {
    FileManager.default.fileExists(atPath: "/opt/homebrew") ? configDirs[0] : configDirs[1]
}

struct Tunnel {
    let name: String
    let path: String
    var isUp: Bool { FileManager.default.fileExists(atPath: "\(runDir)/\(name).name") }
}

/// wg-quick derives the interface name from the file name: max 15 chars, limited charset.
func isValidName(_ s: String) -> Bool {
    s.range(of: "^[a-zA-Z0-9_=+.-]{1,15}$", options: .regularExpression) != nil
}

func listTunnels() -> [Tunnel] {
    var seen = Set<String>()
    var result: [Tunnel] = []
    for dir in configDirs {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
        for f in files.sorted() where f.hasSuffix(".conf") {
            let name = String(f.dropLast(5))
            // Skip names wg-quick would reject anyway; also keeps odd filenames out of shell commands.
            guard isValidName(name) else { continue }
            if seen.insert(name).inserted { result.append(Tunnel(name: name, path: "\(dir)/\(f)")) }
        }
    }
    return result
}

// MARK: - Config inspection

/// IPv4 CIDRs from all AllowedIPs lines.
func allowedIPs(_ conf: String) -> [String] {
    confValues(conf, key: "allowedips").flatMap { $0.split(separator: ",") }
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains(".") }
}

/// Values of `Key = value` lines (case-insensitive key).
func confValues(_ conf: String, key: String) -> [String] {
    conf.split(whereSeparator: \.isNewline).compactMap { line in
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == key else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }
}

/// PreUp/PostUp/PreDown/PostDown lines — wg-quick runs these as root via bash.
func hookLines(_ conf: String) -> [String] {
    conf.split(whereSeparator: \.isNewline).map(String.init).filter {
        $0.range(of: #"^\s*(PreUp|PostUp|PreDown|PostDown)\s*="#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

func parseCIDR(_ s: String) -> (UInt32, UInt32)? {
    let p = s.split(separator: "/")
    guard let first = p.first else { return nil }
    let o = first.split(separator: ".").compactMap { UInt32($0) }
    guard o.count == 4, o.allSatisfy({ $0 < 256 }) else { return nil }
    let bits = p.count > 1 ? min(UInt32(p[1]) ?? 32, 32) : 32
    let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
    return ((o[0] << 24 | o[1] << 16 | o[2] << 8 | o[3]) & mask, mask)
}

/// Two CIDRs overlap if they agree on the shorter prefix.
func cidrOverlap(_ a: String, _ b: String) -> Bool {
    guard let (na, ma) = parseCIDR(a), let (nb, mb) = parseCIDR(b) else { return false }
    let m = ma & mb
    return na & m == nb & m
}

func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

// MARK: - Hook approval
//
// A config with PostUp/etc. hooks runs arbitrary commands as root. The config folder is user-writable,
// so anything running as the user could plant hooks and wait for the next admin prompt. We therefore
// remember the SHA-256 of each config whose hooks the user explicitly approved and ask again whenever
// a config with hooks is new or has changed.

enum HookApproval {
    static let key = "approvedHookHashes"
    static var approved: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: key) }
    }
    static func approve(_ data: Data) { approved.insert(sha256(data)) }
    static func isApproved(_ data: Data) -> Bool { approved.contains(sha256(data)) }
}

// MARK: - Privileged execution

/// Runs a shell command as root via the standard macOS admin dialog.
/// NSAppleScript runs in-process, so macOS caches the authorization for a few minutes.
@discardableResult
func runAsAdmin(_ command: String) throws -> String {
    let full = "export PATH=\(binDirs.joined(separator: ":")):/usr/bin:/bin:/usr/sbin:/sbin; \(command) 2>&1"
    let escaped = full.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")!
    var error: NSDictionary?
    let out = script.executeAndReturnError(&error)
    if let error {
        let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
        throw NSError(domain: "WGToggle", code: error[NSAppleScript.errorNumber] as? Int ?? 1,
                      userInfo: [NSLocalizedDescriptionKey: msg])
    }
    return out.stringValue ?? ""
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var installing = false
    var installError: String?
    var lastState: [String: Bool] = [:]

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
        if CommandLine.arguments.contains("--show-logs") { MainActor.assumeIsolated { LogExplorer.show() } }
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
            }
        }
        lastState = state

        let symbol = up.isEmpty ? "shield" : (up.count == tunnels.count ? "shield.fill" : "shield.lefthalf.filled")
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "WireGuard")?.withSymbolConfiguration(cfg)
        img?.isTemplate = true   // monochrome, adapts to light/dark menu bar
        statusItem.button?.image = img
        statusItem.button?.toolTip = up.isEmpty ? "WireGuard: all down"
            : "WireGuard up: " + up.map(\.name).joined(separator: ", ")
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
                menu.addItem(mi)
            }
            menu.addItem(.separator())
            menu.addItem(item("Connect All", #selector(allUp)))
            menu.addItem(item("Disconnect All", #selector(allDown)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Import Config Files…", #selector(importConfig)))
        menu.addItem(item("Add Tunnel (Paste Config)…", #selector(pasteConfig)))
        if !tunnels.isEmpty {
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
        menu.addItem(item("Open Config Folder", #selector(openFolder)))
        menu.addItem(item("Log Explorer…", #selector(showLog), key: "l"))
        let dock = item("Show in Dock", #selector(toggleDock))
        dock.state = Dock.visible ? .on : .off
        menu.addItem(dock)
        let notif = item("Notifications", #selector(toggleNotifications))
        notif.state = Notify.enabled ? .on : .off
        menu.addItem(notif)
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
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
        Log.info("wg-quick \(verb): \(allowed.map(\.name).joined(separator: ", "))")
        // "up" stops at the first failure; "down" keeps going so one bad tunnel doesn't strand others.
        let cmd = allowed.map { "wg-quick \(verb) \(shellQuote($0.path))" }.joined(separator: up ? " && " : "; ")
        let names = allowed.map(\.name).joined(separator: ", ")
        run(cmd, what: "wg-quick \(verb)", status: "\(up ? "Connecting" : "Disconnecting") \(names)…")
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
        guard busy == nil else { Log.warn("\(what) ignored: busy with \(busy!)"); return }
        busy = status ?? "Working…"
        startBlink()
        adminQueue.async {
            var failure: String?
            var cancelled = false
            do {
                let out = try runAsAdmin(command)
                Log.info("\(what) ok\n\(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            } catch let e as NSError where e.code == -128 {
                cancelled = true
            } catch {
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.busy = nil
                self.stopBlink()
                if cancelled { Log.info("\(what): admin prompt cancelled") }
                if let failure {
                    Log.error("\(what) failed: \(failure)")
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
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                button.animator().alphaValue = phase % 2 == 0 ? 1.0 : 0.45
            }
        }
        RunLoop.main.add(blinkTimer!, forMode: .common)   // keep animating while the menu is open
    }

    func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
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

    func addTunnel(suggestedName: String, contents: String) {
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
        if let t = listTunnels().first(where: { $0.name == name }), !confirm("Replace existing \(name)?\n\(t.path)") { return }

        // Routes that would clash with other tunnels, or capture all traffic.
        let newRoutes = allowedIPs(contents)
        var clashes: [String] = []
        for t in existing {
            guard let other = try? String(contentsOfFile: t.path, encoding: .utf8) else { continue }
            for a in newRoutes { for b in allowedIPs(other) where cidrOverlap(a, b) { clashes.append("\(a) ↔ \(t.name): \(b)") } }
        }
        if newRoutes.contains("0.0.0.0/0") { clashes.append("0.0.0.0/0 sends ALL traffic through \(name)") }
        if !confValues(contents, key: "dns").isEmpty {
            clashes.append("DNS = … replaces your system DNS for ALL lookups while \(name) is up")
        }
        if !clashes.isEmpty {
            Log.warn("add: \(name) warnings: \(clashes.joined(separator: " | "))")
            if !confirm("\(name) may disturb other tunnels or your internet:\n\n"
                        + clashes.prefix(8).joined(separator: "\n") + "\n\nAdd anyway?", button: "Add Anyway") { return }
        }

        // Hooks run as root: approve at import time so connecting later doesn't surprise the user.
        let data = Data(contents.utf8)
        let hooks = hookLines(contents)
        if !hooks.isEmpty {
            guard approveHooks(name: name, hooks: hooks) else { Log.warn("add: \(name) hooks rejected"); return }
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
        appMenu.addItem(withTitle: "About WGToggle", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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
                    Log.error("brew install failed (exit \(p.terminationStatus)):\n\(out.suffix(2000))")
                    Notify.error("Installing wireguard-tools failed", self.installError ?? "")
                    self.alert("Installing wireguard-tools failed", String(out.suffix(1500)))
                } else {
                    Log.info("wireguard-tools installed")
                    Notify.post(title: "wireguard-tools installed", body: "wg-quick is ready.")
                }
            }
        }
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

/// "Show in Dock" preference: .regular shows a Dock icon + app menu bar, .accessory is menu-bar-only.
enum Dock {
    static let key = "showInDock"
    static var visible: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static func apply() {
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        if visible { NSApp.activate(ignoringOtherApps: true) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
