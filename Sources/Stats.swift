import Foundation
import Darwin

// MARK: - Live stats & health
//
// Byte counters come from getifaddrs() (no root needed). The utun interface of a tunnel is found by
// matching its configured Address, or via the helper in passwordless mode, which also reports the
// latest handshake time.

struct TunnelStats {
    var iface: String?
    var address: String?
    var rx: UInt64 = 0
    var tx: UInt64 = 0
    var handshake: Date?
    var stuck = false
    /// Peers (short public key) that get traffic but haven't completed a handshake recently.
    /// Only filled for tunnels with several peers, in passwordless mode.
    var stalePeers: [String] = []
}

/// A peer is stale when something was sent to it during the window but its handshake is old or missing.
/// Any traffic counts: an unreachable peer only gets ~148-byte handshake initiations, an idle one gets nothing.
func peerIsStale(txDelta: UInt64, handshake: Date?, now: Date = Date(), limit: TimeInterval = HealthMonitor.handshakeLimit) -> Bool {
    txDelta > 0 && (handshake.map { now.timeIntervalSince($0) > limit } ?? true)
}

/// iface → (first IPv4 address, all IPv4/IPv6 addresses, rx bytes, tx bytes)
func interfaceTable() -> [String: (addr: String?, addrs: Set<String>, rx: UInt64, tx: UInt64)] {
    var result: [String: (addr: String?, addrs: Set<String>, rx: UInt64, tx: UInt64)] = [:]
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return result }
    defer { freeifaddrs(head) }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let ifa = p {
        defer { p = ifa.pointee.ifa_next }
        let name = String(cString: ifa.pointee.ifa_name)
        guard name.hasPrefix("utun"), let sa = ifa.pointee.ifa_addr else { continue }
        var entry = result[name] ?? (nil, [], 0, 0)
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var a = sin.pointee.sin_addr
                inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
            }
            entry.addr = entry.addr ?? String(cString: buf)
            entry.addrs.insert(String(cString: buf))
        case AF_INET6:
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin in
                var a = sin.pointee.sin6_addr
                inet_ntop(AF_INET6, &a, &buf, socklen_t(INET6_ADDRSTRLEN))
            }
            entry.addrs.insert(String(cString: buf))   // IPv6-only tunnels are found by this
        default: break
        }
        result[name] = entry
    }
    // getifaddrs() rounds byte counters to whole KB; read exact 64-bit counters like netstat does.
    for (name, c) in exactCounters() where name.hasPrefix("utun") {
        var e = result[name] ?? (nil, [], 0, 0)
        e.rx = c.rx; e.tx = c.tx
        result[name] = e
    }
    return result
}

/// iface → exact (rx, tx) bytes via sysctl NET_RT_IFLIST2 (if_data64).
func exactCounters() -> [String: (rx: UInt64, tx: UInt64)] {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var len = 0
    guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
    var buf = [UInt8](repeating: 0, count: len)
    guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }
    var out: [String: (rx: UInt64, tx: UInt64)] = [:]
    buf.withUnsafeBytes { raw in
        var off = 0
        // Every routing message starts with msglen (UInt16), version (UInt8), type (UInt8); other message
        // kinds (addresses) are shorter than if_msghdr, so only that common header is read for all of them.
        while off + 4 <= len {
            let msglen = Int(raw.loadUnaligned(fromByteOffset: off, as: UInt16.self))
            let type = Int32(raw.load(fromByteOffset: off + 3, as: UInt8.self))
            guard msglen >= 4, off + msglen <= len else { break }   // malformed/truncated
            if type == RTM_IFINFO2, msglen >= MemoryLayout<if_msghdr2>.size {
                let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                var nameBuf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                if if_indextoname(UInt32(m.ifm_index), &nameBuf) != nil {
                    out[String(cString: nameBuf)] = (m.ifm_data.ifi_ibytes, m.ifm_data.ifi_obytes)
                }
            }
            off += msglen
        }
    }
    return out
}

/// Only ever used from the app's stats queue (and once by the CLI), never concurrently.
final class HealthMonitor: @unchecked Sendable {
    /// Seconds of "traffic out, nothing back" before a tunnel is called stuck.
    static let window: TimeInterval = 40
    static let handshakeLimit: TimeInterval = 200   // WireGuard re-handshakes every ~2 min under traffic

    private var samples: [String: [(Date, UInt64, UInt64)]] = [:]
    private(set) var stats: [String: TunnelStats] = [:]
    private var notifiedStuck = Set<String>()
    private var peerSamples: [String: [(Date, UInt64)]] = [:]
    private var notifiedPeers = Set<String>()

    /// Called every few seconds off the main thread.
    func sample(tunnels: [Tunnel]) -> (stats: [String: TunnelStats], newlyStuck: [String], newlyStalePeers: [(String, String)]) {
        let table = interfaceTable()
        let helper = Helper.cachedStatus() ?? [:]
        let now = Date()
        var newStats: [String: TunnelStats] = [:]
        var newlyStuck: [String] = []
        var newlyStalePeers: [(String, String)] = []

        for t in tunnels where t.isUp {
            var s = TunnelStats()
            if let h = helper[t.name] {
                s.iface = h.iface
                s.handshake = h.handshake
                s.address = table[h.iface]?.addr ?? table[h.iface]?.addrs.sorted().first
            } else if let addr = tunnelAddress(t.path),
                      let iface = table.first(where: { $0.value.addrs.contains(addr) })?.key {
                s.iface = iface
                s.address = addr
            }
            if let iface = s.iface, let c = table[iface] { s.rx = c.rx; s.tx = c.tx }

            // Keep a short history; judge over the window.
            var hist = (samples[t.name] ?? []).filter { now.timeIntervalSince($0.0) <= Self.window + 10 }
            hist.append((now, s.rx, s.tx))
            samples[t.name] = hist
            // Counters went backwards (interface re-created): start the window over.
            if let oldest = hist.first, s.rx < oldest.1 || s.tx < oldest.2 { hist = [(now, s.rx, s.tx)] }
            samples[t.name] = hist
            if let oldest = hist.first, now.timeIntervalSince(oldest.0) >= Self.window {
                let rxDelta = s.rx - oldest.1, txDelta = s.tx - oldest.2
                // Data leaves but (almost) nothing comes back: only handshake-sized replies.
                // With a handshake time (passwordless mode) trust it: a fresh handshake means the peer is alive,
                // even if traffic is one-way. Without it, fall back to "data out, nothing back".
                if let h = s.handshake {
                    s.stuck = now.timeIntervalSince(h) > Self.handshakeLimit && txDelta > 2_000
                } else {
                    s.stuck = txDelta > 2_000 && rxDelta < 400
                }
            }
            // Per peer (multi-peer configs): one healthy peer must not hide a dead one.
            if let peers = helper[t.name]?.peers, peers.count > 1 {
                for p in peers {
                    let key = "\(t.name)/\(p.key)"
                    var hist = (peerSamples[key] ?? []).filter { now.timeIntervalSince($0.0) <= Self.window + 10 }
                    if let o = hist.first, p.tx < o.1 { hist = [] }   // counters reset
                    hist.append((now, p.tx))
                    peerSamples[key] = hist
                    let short = String(p.key.prefix(8)) + "…"
                    if let o = hist.first, now.timeIntervalSince(o.0) >= Self.window,
                       peerIsStale(txDelta: p.tx - o.1, handshake: p.handshake, now: now) {
                        s.stalePeers.append(short)
                        if notifiedPeers.insert(key).inserted { newlyStalePeers.append((t.name, short)) }
                    } else {
                        notifiedPeers.remove(key)
                    }
                }
            }
            if s.stuck && !notifiedStuck.contains(t.name) { newlyStuck.append(t.name); notifiedStuck.insert(t.name) }
            if !s.stuck { notifiedStuck.remove(t.name) }
            newStats[t.name] = s
        }
        for name in samples.keys where newStats[name] == nil { samples[name] = nil; notifiedStuck.remove(name) }
        // Drop peer history for tunnels that are down and peers that left the config.
        let live = Set(newStats.keys.flatMap { n in (helper[n]?.peers ?? []).map { "\(n)/\($0.key)" } })
        peerSamples = peerSamples.filter { live.contains($0.key) }
        notifiedPeers.formIntersection(live)
        stats = newStats
        return (newStats, newlyStuck, newlyStalePeers)
    }
}

func formatBytes(_ b: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .binary)
}

func formatAgo(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    return "\(s / 3600)h ago"
}

/// Auto-restart backoff: 10s, 20s, 40s, then give up until 15 minutes pass. nil = don't restart.
func restartDelay(previous: [Date], now: Date = Date()) -> TimeInterval? {
    let recent = previous.filter { now.timeIntervalSince($0) < 15 * 60 }
    return recent.count >= 3 ? nil : 10 * pow(2, Double(recent.count))
}

/// Two or more separate "stuck" episodes within 15 minutes (it recovered in between): most likely the same
/// config, i.e. the same key, is connected on another device and the server keeps switching between them.
func suspectSharedConfig(episodes: [Date], now: Date = Date()) -> Bool {
    episodes.filter { now.timeIntervalSince($0) < 15 * 60 }.count >= 2
}
