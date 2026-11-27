import AppKit
import Carbon.HIToolbox
import CoreImage

// MARK: - Split DNS conversion
//
// `DNS = 10.0.0.53, 10.0.0.54, corp` makes wg-quick on macOS send ALL lookups to the VPN.
// Converting replaces it with /etc/resolver/<domain> hooks so only those domains use the VPN's DNS.

enum SplitDNS {
    struct Plan { let servers: [String]; let domains: [String] }

    static func plan(_ conf: String) -> Plan? {
        let tokens = confValues(conf, key: "dns").flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        let isIP: (String) -> Bool = { t in
            var v4 = in_addr(), v6 = in6_addr()
            return inet_pton(AF_INET, t, &v4) == 1 || inet_pton(AF_INET6, t, &v6) == 1
        }
        let servers = tokens.filter(isIP)
        let domains = tokens.filter { !isIP($0) && $0.range(of: "^[A-Za-z0-9]([A-Za-z0-9.-]{0,250}[A-Za-z0-9])?$", options: .regularExpression) != nil }
        return Plan(servers: servers, domains: domains.map { $0.lowercased() })
    }

    /// Removes DNS lines; when domains are known, adds resolver hooks right after [Interface].
    static let resolverDir = "/etc/resolver"
    /// One marker per (domain, interface) while a tunnel is up; /var/run is cleared at boot.
    static let markerDir = "/var/run/wgtoggle-dns"

    /// Hook lines for one domain. Several tunnels can share a domain: each leaves a marker, and the
    /// resolver file is only removed when no marker of a still-running tunnel (live wireguard-go socket) is left.
    static func hooks(domain d: String, nameservers ns: String, resolverDir: String = resolverDir,
                      markerDir: String = markerDir, runDir: String = "/var/run/wireguard") -> [String] {
        [
            "PostUp = mkdir -p \(resolverDir) \(markerDir) && printf '\(ns)' > \(resolverDir)/\(d) && touch \(markerDir)/\(d).%i",
            "PostDown = rm -f \(markerDir)/\(d).%i; for m in \(markerDir)/\(d).*; do [ -S \"\(runDir)/${m##*.}.sock\" ] && exit 0; done; rm -f \(resolverDir)/\(d)",
        ]
    }

    static func convert(_ conf: String, plan: Plan) -> String {
        var lines = conf.components(separatedBy: "\n").filter {
            $0.range(of: #"^\s*DNS\s*="#, options: [.regularExpression, .caseInsensitive]) == nil
        }
        guard !plan.domains.isEmpty, !plan.servers.isEmpty,
              let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "[interface]" })
        else { return lines.joined(separator: "\n") }
        let ns = plan.servers.map { "nameserver \($0)\\n" }.joined()
        var hooks = ["# Split DNS (added by WGToggle): only these domains use the VPN's DNS"]
        for d in plan.domains { hooks += Self.hooks(domain: d, nameservers: ns) }
        lines.insert(contentsOf: hooks, at: i + 1)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Profiles

enum Profiles {
    static let key = "profiles"
    /// name → tunnel names
    static var all: [String: [String]] {
        get { (UserDefaults.standard.dictionary(forKey: key) as? [String: [String]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// MARK: - Auto-connect

enum AutoConnect {
    static let key = "autoConnect"
    static var tunnels: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: key) }
    }
    static let restartKey = "autoRestartStuck"
    static var restartStuck: Bool {
        get { UserDefaults.standard.bool(forKey: restartKey) }
        set { UserDefaults.standard.set(newValue, forKey: restartKey) }
    }
}

// MARK: - Update check (GitHub Releases, no third-party framework)

enum Updates {
    static let repo = "ppodolak/wgtoggle"
    static let autoKey = "checkUpdates"
    static var auto: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    struct Release { let version: String; let url: URL }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Only sends a plain GET to api.github.com; no identifiers.
    static func check(completion: @escaping (Release?, String?) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("WGToggle", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, err in
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String, let page = obj["html_url"] as? String, let url = URL(string: page)
            else { return completion(nil, err?.localizedDescription ?? "no release info") }
            let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            completion(isNewer(v, than: current) ? Release(version: v, url: url) : nil, nil)
        }.resume()
    }
}

// MARK: - Global shortcut ⌃⌥⌘T (Carbon hot key: no Accessibility permission needed)

enum HotKey {
    static let key = "globalShortcut"
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
    static let label = "⌃⌥⌘T"
    private static var ref: EventHotKeyRef?
    private static var handlerInstalled = false
    static var action: (() -> Void)?

    static func apply() {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        guard enabled else { return }
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.action?() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x5747_5447), id: 1)  // 'WGTG'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey | cmdKey), id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { Log.warn("global shortcut \(label) unavailable (\(status)), maybe used by another app") }
    }
}

// MARK: - QR import

enum QRImport {
    /// Decodes the first QR code in an image (WireGuard portals show configs as QR codes).
    static func decode(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff),
              let det = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else { return nil }
        return det.features(in: ci).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}
