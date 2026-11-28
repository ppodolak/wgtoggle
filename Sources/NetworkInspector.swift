import AppKit
import SwiftUI

// Network Inspector: what each tunnel routes, which DNS domains it manages, what conflicts, and which
// split-DNS resolvers are active right now. Read-only; loaded off the main thread (root-owned configs go
// through the helper's key-free `meta`).

struct InspectorTunnel: Identifiable {
    let id: String
    let state: Tunnel.State
    let address: String?
    let routes: [String]
    let dnsDomains: [String]
    let check: String?
    let readable: Bool
}

struct InspectorSnapshot {
    var tunnels: [InspectorTunnel] = []
    var conflictList: [String] = []
    var resolvers: [(domain: String, servers: String)] = []
    var takenAt = Date()

    static func load() -> InspectorSnapshot {
        var snap = InspectorSnapshot()
        if demoMode {   // screenshots: sample data only, never the real configs or /etc/resolver
            snap.tunnels = [
                InspectorTunnel(id: "dev", state: .up, address: "10.8.0.2", routes: ["10.8.0.0/16", "172.20.0.0/16"], dnsDomains: ["dev.corp"], check: "10.8.0.1:22", readable: true),
                InspectorTunnel(id: "homelab", state: .down, address: "10.30.0.4", routes: ["192.168.50.0/24"], dnsDomains: [], check: nil, readable: true),
                InspectorTunnel(id: "prod", state: .up, address: "10.20.0.5", routes: ["10.20.0.0/16", "172.20.5.0/24"], dnsDomains: ["prod.corp"], check: "https://grafana.prod.corp/healthz", readable: true),
            ]
            snap.conflictList = ["prod: 172.20.5.0/24 overlaps dev: 172.20.0.0/16"]
            snap.resolvers = [("dev.corp", "10.8.0.53"), ("prod.corp", "10.20.0.53")]
            return snap
        }
        let tunnels = listTunnels()
        var texts: [(name: String, conf: String)] = []
        for t in tunnels {
            let text = configText(t)
            if let text { texts.append((t.name, text)) }
            snap.tunnels.append(InspectorTunnel(
                id: t.name, state: t.state, address: tunnelAddress(t.path),
                routes: text.map(allowedIPs) ?? [],
                dnsDomains: text.map { Array(resolverDomains($0)).sorted() + confValues($0, key: "dns") } ?? [],
                check: ConnectivityCheck.targets[t.name], readable: text != nil))
        }
        for (i, t) in texts.enumerated() { snap.conflictList += conflicts(name: t.name, conf: t.conf, others: Array(texts[(i + 1)...])) }
        let dir = "/etc/resolver"
        for f in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() {
            let ns = ((try? String(contentsOfFile: "\(dir)/\(f)", encoding: .utf8)) ?? "")
                .split(separator: "\n").filter { $0.hasPrefix("nameserver") }.map { $0.dropFirst(11) }
            snap.resolvers.append((f, ns.joined(separator: ", ")))
        }
        snap.takenAt = Date()
        return snap
    }
}

@MainActor
final class InspectorModel: ObservableObject {
    @Published var snapshot = InspectorSnapshot()
    @Published var loading = false
    func refresh() {
        loading = true
        DispatchQueue.global().async {
            let s = InspectorSnapshot.load()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.snapshot = s; self.loading = false } }
        }
    }
}

struct NetworkInspectorView: View {
    @StateObject private var model = InspectorModel()

    var body: some View {
        List {
            Section("Tunnels") {
                ForEach(model.snapshot.tunnels) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: t.state == .up ? "checkmark.shield" : t.state == .down ? "shield" : "questionmark.circle")
                                .foregroundStyle(t.state == .up ? Color.green : .secondary)
                            Text(t.id).font(.headline)
                            Text(t.state == .up ? "up" : t.state == .down ? "down" : "unknown").foregroundStyle(.secondary)
                            if let a = t.address { Text(a).font(.callout.monospaced()).foregroundStyle(.secondary) }
                        }
                        if !t.readable {
                            Text("Config not readable (root-owned and no helper)").font(.caption).foregroundStyle(.secondary)
                        }
                        if !t.routes.isEmpty {
                            Text("Routes: " + t.routes.joined(separator: ", ")).font(.callout.monospaced()).textSelection(.enabled)
                        }
                        if !t.dnsDomains.isEmpty {
                            Text("DNS: " + t.dnsDomains.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                        }
                        if let c = t.check { Text("Connectivity check: \(c)").font(.callout).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 2)
                }
            }
            Section("Conflicts") {
                if model.snapshot.conflictList.isEmpty {
                    Label("No overlapping routes, default routes or shared DNS domains", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(model.snapshot.conflictList, id: \.self) { c in
                    Label(c, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            Section("Active split-DNS resolvers (/etc/resolver)") {
                if model.snapshot.resolvers.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(model.snapshot.resolvers, id: \.domain) { r in
                    HStack { Text(r.domain).font(.callout.monospaced()); Spacer(); Text(r.servers).font(.callout.monospaced()).foregroundStyle(.secondary) }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .toolbar {
            ToolbarItem {
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(model.loading)
            }
        }
        .onAppear { model.refresh() }
    }
}

@MainActor
enum NetworkInspector {
    private static var window: NSWindow?
    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Network Inspector"
            w.toolbar = NSToolbar(identifier: "inspector")
            w.contentViewController = NSHostingController(rootView: NetworkInspectorView())
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("NetworkInspector")
            if !w.setFrameUsingName("NetworkInspector") { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
