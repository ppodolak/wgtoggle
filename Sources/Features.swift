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
    /// Per (domain, interface) marker holding that tunnel's nameservers, plus the saved original resolver.
    /// Persistent (not /var/run): after a reboot, leftover markers show the resolver is ours, so it's never
    /// mistaken for a foreign file, and the saved original isn't lost. Dead markers are pruned on disconnect.
    static let markerDir = "/var/db/wgtoggle-dns"

    /// Hook lines for one domain. Several tunnels can share a domain, even with different nameservers:
    /// each running tunnel keeps its own resolver content in a marker. On disconnect the resolver is rebuilt
    /// from the newest marker of a tunnel that's still running (live wireguard-go socket), and when none is
    /// left, a resolver file that existed before WGToggle took over is put back (otherwise it's removed).
    /// Shell test "marker $m belongs to a tunnel that's running right now". Markers are named
    /// `<domain>.if.<utun>@<tunnel>`: the utun must have a live wireguard-go socket AND wg-quick's runtime
    /// name file for that tunnel must point at the same utun. utun names get reused after a reboot, so the
    /// socket alone could belong to a different VPN.
    static func aliveTest(_ W: String) -> String {
        #"x="utun${m##*.if.utun}"; i="${x%%@*}"; n="${x#*@}"; [ "$x" != "$i" ] && [ -S "\#(W)/$i.sock" ] && [ "$(cat "\#(W)/$n.name" 2>/dev/null)" = "$i" ]"#
    }

    static func hooks(domain d: String, nameservers ns: String, resolverDir R: String = resolverDir,
                      markerDir M: String = markerDir, runDir W: String = "/var/run/wireguard") -> [String] {
        [
            // keep a resolver file someone else created, the first time we take over this domain
            "PostUp = mkdir -p \(R) \(M) && if [ -e \(R)/\(d) ] && ! ls \(M)/\(d).if.* >/dev/null 2>&1; then cp -p \(R)/\(d) \(M)/\(d).orig; fi",
            "PostUp = printf '\(ns)' > '\(M)/\(d).if.%i@%I' && cp '\(M)/\(d).if.%i@%I' \(R)/\(d)",
            "PostDown = rm -f '\(M)/\(d).if.%i@%I'",
            "PostDown = for m in $(ls -t \(M)/\(d).if.* 2>/dev/null); do if \(aliveTest(W)); then cp \"$m\" \(R)/\(d); exit 0; fi; rm -f \"$m\"; done; if [ -e \(M)/\(d).orig ]; then mv \(M)/\(d).orig \(R)/\(d); else rm -f \(R)/\(d); fi",
        ]
    }

    /// Root shell snippet: for every domain WGToggle manages, drop markers of tunnels that aren't running
    /// and rebuild the resolver from one that is, else restore the saved original, else remove it.
    /// Fixes resolvers left behind by a crash or an unexpected reboot. Running it twice changes nothing.
    static func repairScript(resolverDir R: String = resolverDir, markerDir M: String = markerDir,
                             runDir W: String = "/var/run/wireguard") -> String {
        #"""
        M=\#(M); R=\#(R); W=\#(W)
        [ -d "$M" ] || { echo "nothing to repair"; exit 0; }
        for d in $(ls "$M" | sed -E 's/\.if\.utun[0-9]+(@.*)?$//; s/\.orig$//' | grep -E '^[A-Za-z0-9.-]+$' | sort -u); do
          live=""
          for m in $(ls -t "$M/$d".if.* 2>/dev/null); do
            if \#(aliveTest(W)); then [ -n "$live" ] || live="$m"; else rm -f "$m"; fi
          done
          if [ -n "$live" ]; then cmp -s "$live" "$R/$d" || cp "$live" "$R/$d"; echo "$d: in use by ${live##*@}"
          elif [ -e "$M/$d.orig" ]; then mv "$M/$d.orig" "$R/$d"; echo "$d: original resolver restored"
          elif [ -e "$R/$d" ]; then rm -f "$R/$d"; echo "$d: stale resolver removed"
          fi
        done
        """#
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

    /// Semver-ish: 1.10 > 1.9, and a release beats its prerelease (1.7.0 > 1.7.0-beta.2).
    static func isNewer(_ a: String, than b: String) -> Bool {
        func split(_ v: String) -> ([Int], String?) {
            let parts = v.split(separator: "-", maxSplits: 1)
            return (parts[0].split(separator: ".").map { Int($0) ?? 0 }, parts.count > 1 ? String(parts[1]) : nil)
        }
        let (pa, ra) = split(a), (pb, rb) = split(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        switch (ra, rb) {
        case (nil, nil), (.some, nil): return false
        case (nil, .some): return true
        case let (.some(x), .some(y)): return x.compare(y, options: .numeric) == .orderedDescending
        }
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
