import AppKit
import CryptoKit
import OSLog

// MARK: - Logging
//
// Two sinks:
//   • Unified log (Console.app, `log stream --predicate 'subsystem == "local.wgtoggle"'`)
//   • ~/Library/Logs/WGToggle/wgtoggle.log (rotated at 1 MB, one backup kept)
// Config contents and keys are NEVER logged — only names, paths, commands and wg-quick output.

/// `--demo`: sample tunnels, stats and log for screenshots. Never reads real configs or the real log.
let demoMode = CommandLine.arguments.contains("--demo")

enum Demo {
    static let up = Set((CommandLine.arguments.first { $0.hasPrefix("--demo-up=") }?.dropFirst(10)
        .split(separator: ",").map(String.init)) ?? ["dev", "prod"])
    static let tunnels = ["dev", "homelab", "prod"].map { Tunnel(name: $0, path: "/opt/homebrew/etc/wireguard/\($0).conf") }
    static let stats: [String: TunnelStats] = [
        "dev": TunnelStats(iface: "utun6", address: "10.8.0.2", rx: 48_312_005, tx: 6_220_114, handshake: Date().addingTimeInterval(-14)),
        "prod": TunnelStats(iface: "utun7", address: "10.20.0.5", rx: 2_093_440, tx: 731_902, handshake: Date().addingTimeInterval(-41)),
    ]
}

enum Log {
    static let os = Logger(subsystem: "local.wgtoggle", category: "app")
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/WGToggle")
    static let file = demoMode ? URL(fileURLWithPath: NSTemporaryDirectory() + "wgtoggle-demo.log")
        : dir.appendingPathComponent("wgtoggle.log")
    static let queue = DispatchQueue(label: "wgtoggle.log")
    static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func info(_ m: String, detail: String? = nil) { emit(.info, "INFO ", m, detail) }
    static func warn(_ m: String, detail: String? = nil) { emit(.default, "WARN ", m, detail) }
    static func error(_ m: String, detail: String? = nil) { emit(.error, "ERROR", m, detail) }

    /// `detail` (command output) is marked private in the unified log; the 0600 log file keeps it in full.
    /// Strips WireGuard keys: `PrivateKey/PresharedKey = …` values, and any bare 44-char base64 key
    /// (public keys too, shortened to a recognisable prefix).
    static func redact(_ s: String) -> String {
        var out = s.replacingOccurrences(of: #"(?i)((?:Private|Preshared)Key\s*=\s*)\S+"#, with: "$1<redacted>", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?<![A-Za-z0-9+/])([A-Za-z0-9+/]{4})[A-Za-z0-9+/]{39}="#, with: "$1…", options: .regularExpression)
        return out
    }

    private static func emit(_ type: OSLogType, _ level: String, _ m0: String, _ detail0: String?) {
        let m = redact(m0), detail = detail0.map(redact)
        if let detail, !detail.isEmpty {
            os.log(level: type, "\(m, privacy: .public)\n\(detail, privacy: .private)")
            write(level, m + "\n" + detail)
        } else {
            os.log(level: type, "\(m, privacy: .public)")
            write(level, m)
        }
    }

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
    if Helper.isInstalled { return Helper.configDir }
    return FileManager.default.fileExists(atPath: "/opt/homebrew") ? configDirs[0] : configDirs[1]
}

struct Tunnel {
    let name: String
    let path: String
    /// wg-quick leaves <name>.name behind if wireguard-go dies, so the name file alone isn't proof.
    /// Up = name file exists AND the tunnel's interface is really there.
    var isUp: Bool { state == .up }

    enum State { case up, down, unknown }

    var state: State {
        if demoMode { return Demo.up.contains(name) ? .up : .down }
        guard FileManager.default.fileExists(atPath: "\(runDir)/\(name).name") else { return .down }
        // Passwordless mode: the helper reads wg-quick's runtime file, i.e. the tunnel's real interface.
        if Helper.isInstalled {
            guard let st = Helper.cachedStatus() else { return .unknown }
            return st[name].map { interfaceTable()[$0.iface] != nil } == true ? .up : .down
        }
        if let addr = tunnelAddress(path) {
            // Same address in another config whose runtime file also exists: ambiguous unless the helper can tell.
            let twins = listTunnels().filter { $0.name != name && tunnelAddress($0.path) == addr
                && FileManager.default.fileExists(atPath: "\(runDir)/\($0.name).name") }
            if !twins.isEmpty {
                guard Helper.isInstalled, let st = Helper.cachedStatus() else { return .unknown }
                return st[name].map { interfaceTable()[$0.iface] != nil } == true ? .up : .down
            }
            return interfaceTable().contains { $0.value.addrs.contains(addr) } ? .up : .down
        }
        // Root-only config: ask the helper which interface belongs to this tunnel and check that one.
        if Helper.isInstalled {
            guard let status = Helper.cachedStatus() else { return .unknown }   // helper failed: don't guess
            return status[name].map { interfaceTable()[$0.iface] != nil } == true ? .up : .down
        }
        // No helper and an unreadable config: a name file alone may be stale, so don't claim it's up.
        return .unknown
    }
}

/// Problems a config would cause next to the others: overlapping routes, invalid entries,
/// default routes, and split-DNS domains another tunnel also manages.
func conflicts(name: String, conf: String, others: [(name: String, conf: String)]) -> [String] {
    var out: [String] = []
    let routes = allowedIPs(conf)
    for r in routes {
        guard let c = parseCIDR(r) else { out.append("\(name): \(r) is not a valid network, wg-quick will reject it"); continue }
        if c.bits == 0 { out.append("\(name): \(r) sends ALL \(c.bytes.count == 4 ? "IPv4" : "IPv6") traffic through it") }
    }
    let domains = resolverDomains(conf)
    for o in others {
        for a in routes { for b in allowedIPs(o.conf) where cidrOverlap(a, b) { out.append("\(name): \(a) overlaps \(o.name): \(b)") } }
        for d in domains.intersection(resolverDomains(o.conf)).sorted() {
            // Both use WGToggle's shared split-DNS hooks: they coordinate, nothing to warn about.
            let shared = "\(SplitDNS.markerDir)/\(d)."
            if conf.contains(shared) && o.conf.contains(shared) { continue }
            out.append("\(name): split DNS for \(d) is also managed by \(o.name), disconnecting either removes it for both")
        }
    }
    return out
}

/// One tunnel operation at a time across the app and the `wgtoggle` CLI.
/// flock(2): released automatically if the holder crashes.
enum OpLock {
    static let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/WGToggle/op.lock").path

    /// Returns the locked file descriptor, or nil if another operation still holds it after `wait` seconds.
    static func acquire(wait: TimeInterval) -> Int32? {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        let deadline = Date().addingTimeInterval(wait)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= deadline { close(fd); return nil }
            usleep(200_000)
        }
        return fd
    }

    static func release(_ fd: Int32) { flock(fd, LOCK_UN); close(fd) }
}

/// Config text for checks: the file if readable, else the helper's key-free view of a root-only config.
func configText(_ t: Tunnel) -> String? {
    (try? String(contentsOfFile: t.path, encoding: .utf8)) ?? Helper.meta(t.name)
}

/// First IPv4 Address of a readable config, e.g. "10.8.0.2".
func tunnelAddress(_ path: String) -> String? {
    guard let conf = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let addrs = confValues(conf, key: "address").flatMap { $0.split(separator: ",") }
        .compactMap { $0.trimmingCharacters(in: .whitespaces).split(separator: "/").first.map(String.init) }
    // Prefer IPv4; IPv6-only tunnels use their IPv6 address, written the way the system prints it.
    if let v4 = addrs.first(where: { $0.contains(".") }) { return v4 }
    var a = in6_addr()
    guard let v6 = addrs.first, inet_pton(AF_INET6, v6, &a) == 1 else { return nil }
    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    inet_ntop(AF_INET6, &a, &buf, socklen_t(INET6_ADDRSTRLEN))
    return String(cString: buf)
}

/// wg-quick derives the interface name from the file name: max 15 chars, limited charset.
func isValidName(_ s: String) -> Bool {
    s.range(of: "^[a-zA-Z0-9_=+.-]{1,15}$", options: .regularExpression) != nil
}

func listTunnels() -> [Tunnel] {
    if demoMode { return Demo.tunnels }
    var seen = Set<String>()
    var result: [Tunnel] = []
    let order = Helper.isInstalled ? [Helper.configDir] + configDirs.filter { $0 != Helper.configDir } : configDirs
    for dir in order {
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

/// CIDRs (IPv4 and IPv6) from all AllowedIPs lines.
func allowedIPs(_ conf: String) -> [String] {
    confValues(conf, key: "allowedips").flatMap { $0.split(separator: ",") }
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// /etc/resolver domains a config's hooks create (split DNS).
func resolverDomains(_ conf: String) -> Set<String> {
    Set(hookLines(conf).flatMap { line in
        line.matches(of: #/\/etc\/resolver\/([A-Za-z0-9.-]+)/#).map { String($0.1).lowercased() }
    })
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

/// Address bytes and prefix length; nil for anything malformed (including prefixes out of range).
func parseCIDR(_ s: String) -> (bytes: [UInt8], bits: Int)? {
    let p = s.split(separator: "/", omittingEmptySubsequences: false)
    guard p.count <= 2 else { return nil }
    let ip = String(p[0])
    var bytes: [UInt8]
    if ip.contains(":") {
        var a = in6_addr()
        guard inet_pton(AF_INET6, ip, &a) == 1 else { return nil }
        bytes = withUnsafeBytes(of: &a) { Array($0) }
    } else {
        var a = in_addr()
        guard inet_pton(AF_INET, ip, &a) == 1 else { return nil }
        bytes = withUnsafeBytes(of: &a) { Array($0) }
    }
    let maxBits = bytes.count * 8
    guard p.count == 2 else { return (bytes, maxBits) }
    guard let bits = Int(p[1]), (0...maxBits).contains(bits) else { return nil }
    return (bytes, bits)
}

/// Two CIDRs of the same family overlap if they agree on the shorter prefix.
func cidrOverlap(_ a: String, _ b: String) -> Bool {
    guard let x = parseCIDR(a), let y = parseCIDR(b), x.bytes.count == y.bytes.count else { return false }
    var left = min(x.bits, y.bits)
    for i in 0..<x.bytes.count where left > 0 {
        let mask: UInt8 = left >= 8 ? 0xff : ~(0xff >> UInt8(left))
        if x.bytes[i] & mask != y.bytes[i] & mask { return false }
        left -= 8
    }
    return true
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
/// Where root runs WireGuard tools from: the root-owned copies if installed, else Homebrew's.
func toolsDir() -> String? {
    Helper.toolsInstalled ? Helper.dir : (findBinary("wg-quick") as NSString?)?.deletingLastPathComponent
}

/// Shell command running wg-quick by absolute path with its bash 4+ (never via PATH lookup).
func wgQuick(_ verb: String, _ path: String) -> String {
    let d = toolsDir() ?? "/opt/homebrew/bin"
    return "\(shellQuote(d + "/bash")) \(shellQuote(d + "/wg-quick")) \(verb) \(shellQuote(path))"
}

@discardableResult
func runAsAdmin(_ command: String, timeout: TimeInterval = 300) throws -> String {
    // Homebrew's tools are user-writable; prefer the root-owned copies from passwordless mode when present.
    // System directories FIRST: as root, `cp`, `install`, `shasum`… must never resolve to a user-writable
    // Homebrew file. The WireGuard tools come last (only `wg`/`wireguard-go` live there), and wg-quick itself
    // is always started by absolute path (see wgQuick()).
    let full = "export PATH=/usr/bin:/bin:/usr/sbin:/sbin:\(toolsDir() ?? "/nonexistent"); \(command) 2>&1"
    // On the main thread (short reads like `cat`): run directly.
    if Thread.isMainThread { return try appleScriptAdmin(full) }

    // Off the main thread: the password dialog must be shown from main, but the work must not run there
    // (an install takes seconds and would freeze the app). So main only asks for the password and starts a
    // detached root job; this thread then waits for its result file.
    // Results live in a fresh root-owned 0711 dir in /tmp with an unguessable output file name, so other
    // users can't read the output and nothing running as this user can redirect root's writes.
    let launcher = detachedLauncher(full)
    var launched: Result<String, Error>!
    DispatchQueue.main.sync { launched = Result { try appleScriptAdmin(launcher) } }
    let parts = try launched.get().trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
    guard parts.count == 2, parts[0].hasPrefix("/tmp/wgtoggle."), parts[1].hasPrefix(parts[0] + "/o.") else {
        throw NSError(domain: "WGToggle", code: 1, userInfo: [NSLocalizedDescriptionKey: "couldn't start the admin command"])
    }
    let rcPath = parts[0] + "/rc", deadline = Date().addingTimeInterval(timeout)
    while !FileManager.default.fileExists(atPath: rcPath) {
        if Date() > deadline {
            throw NSError(domain: "WGToggle", code: -2, userInfo: [NSLocalizedDescriptionKey: "admin command still running after \(Int(timeout))s"])
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    let out = (try? String(contentsOfFile: parts[1], encoding: .utf8)) ?? ""
    let rc = Int(((try? String(contentsOfFile: rcPath, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
    guard rc == 0 else {
        throw NSError(domain: "WGToggle", code: rc, userInfo: [NSLocalizedDescriptionKey: out.isEmpty ? "admin command failed (exit \(rc))" : out])
    }
    return out
}

/// Shell that starts `full` in the background and immediately prints "<dir> <output file>"; the job writes
/// its exit code to <dir>/rc when done.
func detachedLauncher(_ full: String) -> String {
    """
    find /tmp -maxdepth 1 -name 'wgtoggle.*' -user root -mmin +120 -exec rm -rf {} + 2>/dev/null
    D=$(/usr/bin/mktemp -d /tmp/wgtoggle.XXXXXXXX) || exit 1
    /bin/chmod 711 "$D"
    O=$(/usr/bin/mktemp "$D/o.XXXXXXXXXXXX") && /bin/chmod 644 "$O"
    ( ( \(full) ) > "$O" 2>&1; echo $? > "$D/rc.tmp"; /bin/chmod 644 "$D/rc.tmp"; /bin/mv "$D/rc.tmp" "$D/rc" ) > /dev/null 2>&1 < /dev/null &
    echo "$D $O"
    """
}

/// `do shell script … with administrator privileges`. Must run on the main thread (that's where macOS shows
/// the dialog; elsewhere it fails with "Authorization failed").
private func appleScriptAdmin(_ shell: String) throws -> String {
    let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
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
