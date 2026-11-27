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
}

/// iface → (IPv4 address, rx bytes, tx bytes)
func interfaceTable() -> [String: (addr: String?, rx: UInt64, tx: UInt64)] {
    var result: [String: (addr: String?, rx: UInt64, tx: UInt64)] = [:]
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return result }
    defer { freeifaddrs(head) }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let ifa = p {
        defer { p = ifa.pointee.ifa_next }
        let name = String(cString: ifa.pointee.ifa_name)
        guard name.hasPrefix("utun"), let sa = ifa.pointee.ifa_addr else { continue }
        var entry = result[name] ?? (nil, 0, 0)
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var a = sin.pointee.sin_addr
                inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
            }
            entry.addr = String(cString: buf)
        default: break
        }
        result[name] = entry
    }
    // getifaddrs() rounds byte counters to whole KB; read exact 64-bit counters like netstat does.
    for (name, c) in exactCounters() where name.hasPrefix("utun") {
        var e = result[name] ?? (nil, 0, 0)
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
        while off + MemoryLayout<if_msghdr>.size <= len {
            let hdr = raw.load(fromByteOffset: off, as: if_msghdr.self)
            guard hdr.ifm_msglen > 0 else { break }
            if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                var nameBuf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                if if_indextoname(UInt32(m.ifm_index), &nameBuf) != nil {
                    out[String(cString: nameBuf)] = (m.ifm_data.ifi_ibytes, m.ifm_data.ifi_obytes)
                }
            }
            off += Int(hdr.ifm_msglen)
        }
    }
    return out
}

final class HealthMonitor {
    /// Seconds of "traffic out, nothing back" before a tunnel is called stuck.
    static let window: TimeInterval = 40
    static let handshakeLimit: TimeInterval = 200   // WireGuard re-handshakes every ~2 min under traffic

    private var samples: [String: [(Date, UInt64, UInt64)]] = [:]
    private(set) var stats: [String: TunnelStats] = [:]
    private var notifiedStuck = Set<String>()

    /// Called every few seconds off the main thread.
    func sample(tunnels: [Tunnel]) -> (stats: [String: TunnelStats], newlyStuck: [String]) {
        let table = interfaceTable()
        let helper = Helper.status()
        let now = Date()
        var newStats: [String: TunnelStats] = [:]
        var newlyStuck: [String] = []

        for t in tunnels where t.isUp {
            var s = TunnelStats()
            if let h = helper[t.name] {
                s.iface = h.iface
                s.handshake = h.handshake
                s.address = table[h.iface]?.addr
            } else if let addr = tunnelAddress(t.path),
                      let iface = table.first(where: { $0.value.addr == addr })?.key {
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
                let silent = txDelta > 2_000 && rxDelta < 400
                let staleHandshake = s.handshake.map { now.timeIntervalSince($0) > Self.handshakeLimit && txDelta > 2_000 } ?? false
                s.stuck = silent || staleHandshake
            }
            if s.stuck && !notifiedStuck.contains(t.name) { newlyStuck.append(t.name); notifiedStuck.insert(t.name) }
            if !s.stuck { notifiedStuck.remove(t.name) }
            newStats[t.name] = s
        }
        for name in samples.keys where newStats[name] == nil { samples[name] = nil; notifiedStuck.remove(name) }
        stats = newStats
        return (newStats, newlyStuck)
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
